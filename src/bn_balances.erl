-module(bn_balances).

-include("bn_jsonrpc.hrl").
%% blockchain_follower
-export([
    requires_sync/0,
    requires_ledger/0,
    init/1,
    follower_height/1,
    load_chain/2,
    load_block/5,
    terminate/2
]).

% api
-export([get_historic_balance/2]).
% hooks
-export([incremental_commit_hook/1, end_commit_hook/2]).

-define(DB_FILE, "balances.db").
-define(SERVER, ?MODULE).

-record(state, {
    dir :: file:filename_all(),
    db :: rocksdb:db_handle(),
    default :: rocksdb:cf_handle(),
    entries :: rocksdb:cf_handle(),
    dc_entries :: rocksdb:cf_handle(),
    dc_entries_size :: rocksdb:cf_handle(),
    securities :: rocksdb:cf_handle(),
    securities_size :: rocksdb:cf_handle(),
    entries_size ::rocksdb:cf_handle()
}).

%%
%% Blockchain follower
%%

requires_ledger() -> false.

requires_sync() -> false.

init(Args) ->
    Dir = filename:join(proplists:get_value(base_dir, Args, "data"), ?DB_FILE),
    case load_db(Dir) of
        {ok, State} ->
            ets:new(?MODULE, [public, named_table]),
            persistent_term:put(?MODULE, State),
            {ok, State};
        Error ->
            Error
    end.

follower_height(#state{db = DB, default = DefaultCF}) ->
    case bn_db:get_follower_height(DB, DefaultCF) of
        {ok, Height} -> Height;
        {error, _} = Error -> ?jsonrpc_error(Error)
    end.

load_chain(_Chain, State = #state{}) ->
    {ok, State}.

load_block(_Hash, Block, _Sync, Ledger, State = #state{
    db=DB, 
    default=DefaultCF, 
    entries=EntriesCF
}) ->
    case Ledger of
        undefined ->
            Height = blockchain_block:height(Block),
            bn_db:put_follower_height(DB, DefaultCF, Height),
            {ok, State};
        _ ->
            {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
            case rocksdb:get(DB, DefaultCF, <<"loaded_initial_balances">>, []) of
                not_found ->
                    {ok, Batch} = rocksdb:batch(),
                    lager:info("Loading initial balances at height ~p", [Height]),
                    EntrySnapshotList = blockchain_ledger_v1:snapshot_raw_accounts(Ledger),
                    DCSnapshotList = blockchain_ledger_v1:snapshot_raw_dc_accounts(Ledger),
                    SecuritySnapshotList = blockchain_ledger_v1:snapshot_raw_security_accounts(Ledger),
                    lists:foreach(
                        fun(Entries) ->
                            lists:foreach(
                                fun({AddressBin, _}) ->
                                    HeightEntryKeyBin = <<AddressBin/binary, Height/unsigned-integer>>,
                                    case rocksdb:get(DB, EntriesCF, HeightEntryKeyBin, []) of
                                        not_found ->
                                            EntryBin = case lists:keyfind(AddressBin, 1, EntrySnapshotList) of
                                                {_, EntryBin0} ->
                                                    EntryBin0;
                                                false ->
                                                    ZeroEntry = blockchain_ledger_data_credits_entry_v1:new(0, 0),
                                                    blockchain_ledger_data_credits_entry_v1:serialize(ZeroEntry)
                                            end,
                                            DCBin = case lists:keyfind(AddressBin, 1, DCSnapshotList) of
                                                {_, DCBin0} ->
                                                    DCBin0;
                                                false ->
                                                    DCZeroEntry = blockchain_ledger_data_credits_entry_v1:new(0, 0),
                                                    blockchain_ledger_data_credits_entry_v1:serialize(DCZeroEntry)
                                            end,
                                            SecurityBin = case lists:keyfind(AddressBin, 1, SecuritySnapshotList) of
                                                {_, SecurityBin0} ->
                                                    SecurityBin0;
                                                false ->
                                                    SecurityZeroEntry = blockchain_ledger_security_entry_v1:new(0, 0),
                                                    blockchain_ledger_security_entry_v1:serialize(SecurityZeroEntry)
                                            end,
                                            rocksdb:batch_put(Batch, DB, EntriesCF, HeightEntryKeyBin, <<EntryBin/binary, DCBin/binary, SecurityBin/binary>>, []);
                                        _ ->
                                            ok
                                    end
                                end,
                                Entries
                            )
                        end,
                        [
                            EntrySnapshotList,
                            DCSnapshotList,
                            SecuritySnapshotList
                        ]
                    ),
                    rocksdb:batch_put(Batch, <<"loaded_initial_balances">>, <<"true">>),
                    bn_db:batch_put_follower_height(Batch, DefaultCF, Height),
                    rocksdb:write_batch(DB, Batch, [{sync, true}]);
                {ok, _} ->
                    {ok, Batch} = rocksdb:batch(),
                    lager:info("Loading ledger changes for height ~p", [Height]),
                    TotalKeysChanged = ets:foldl(
                        fun ({Key}, Acc) ->
                            batch_update_entry(Key, Ledger, Batch, Height),
                            Acc + 1
                        end,
                        0,
                        ?MODULE
                    ),
                    lager:info("Total changes: ~p", [TotalKeysChanged]),
                    bn_db:batch_put_follower_height(Batch, DefaultCF, Height),
                    rocksdb:write_batch(DB, Batch, [{sync, true}]),
                    ets:delete_all_objects(?MODULE)
            end,
            {ok, State}
    end.

terminate(_Reason, #state{db = DB}) ->
    rocksdb:close(DB).

%%
%% Hooks
%%

incremental_commit_hook(_Changes) -> 
    ok.

end_commit_hook(_CF, Changes) ->
    Keys = lists:filtermap(
        fun
            ({put, Key}) -> {true, {Key}};
            (_) -> false
        end,
        Changes
    ),
    ets:insert(?MODULE, Keys).

%%
%% Internal
%%

get_state() ->
    bn_db:get_state(?MODULE).

-spec load_db(file:filename_all()) -> {ok, #state{}} | {error, any()}.
load_db(Dir) ->
    case bn_db:open_db(Dir, ["default", "entries", "entries_size", "dc_entries", "dc_entries_size", "securities", "securities_size"]) of
        {error, _Reason} = Error ->
            Error;
        {ok, DB, [DefaultCF, EntriesCF, EntriesSizeCF, DCEntriesCF, DCEntriesSizeCF, SecuritiesCF, SecuritiesSizeCF]} ->
            State = #state{
                dir = Dir,
                db = DB,
                default = DefaultCF,
                entries = EntriesCF,
                entries_size = EntriesSizeCF,
                dc_entries = DCEntriesCF,
                dc_entries_size = DCEntriesSizeCF,
                securities = SecuritiesCF,
                securities_size = SecuritiesSizeCF
            },
            compact_db(State),
            {ok, State}
    end.

batch_update_entry(Key, Ledger, Batch, Height) ->
    {ok, #state{entries=EntriesCF}} = get_state(),
    HeightEntryKeyBin = <<Key/binary, Height/unsigned-integer>>,
    EntryBin = case blockchain_ledger_v1:find_entry(Key, Ledger) of
        {ok, Entry} ->
            blockchain_ledger_entry_v1:serialize(Entry);
        {error,address_entry_not_found} ->
            ZeroEntry = blockchain_ledger_entry_v1:new(0, 0),
            blockchain_ledger_entry_v1:serialize(ZeroEntry)
    end,
    DCBin = case blockchain_ledger_v1:find_dc_entry(Key, Ledger) of
        {ok, DCEntry} ->
            blockchain_ledger_entry_v1:serialize(DCEntry);
        {error,address_entry_not_found} ->
            DCZeroEntry = blockchain_ledger_data_credits_entry_v1:new(0, 0),
            blockchain_ledger_data_credits_entry_v1:serialize(DCZeroEntry)
    end,
    SecurityBin = case blockchain_ledger_v1:find_security_entry(Key, Ledger) of
        {ok, SecurityEntry} ->
            blockchain_ledger_entry_v1:serialize(SecurityEntry);
        {error,address_entry_not_found} ->
            SecurityZeroEntry = blockchain_ledger_security_entry_v1:new(0, 0),
            blockchain_ledger_security_entry_v1:serialize(SecurityZeroEntry)
    end,
    rocksdb:batch_put(Batch, EntriesCF, HeightEntryKeyBin, <<EntryBin/binary, DCBin/binary, SecurityBin/binary>>).

-spec get_historic_balance(AddressBin :: binary(), Height :: pos_integer()) ->
    {ok, map()} | {error, term()}.
get_historic_balance(Key, Height) ->
    {ok, #state{
        db=DB,
        entries=EntriesCF,
        entries_size = EntriesSizeCF,
        dc_entries = DCEntriesCF,
        dc_entries_size = DCEntriesSizeCF,
        securities = SecuritiesCF,
        securities_size = SecuritiesSizeCF
    }} = get_state(),
    case rocksdb:get(DB, <<"initial_height">>, []) of
        {ok, HeightBin} ->
            InitialHeight = binary_to_integer(HeightBin),
            case InitialHeight > Height of
                true ->
                    {error, height_too_old};
                false ->
                    lists:foldl(
                        fun({CF, SizeCF}, Acc) ->
                            Account = case rocksdb:get(DB, SizeCF, Key, []) of
                                {ok, SizeBin} ->
                                    Size = binary_to_integer(SizeBin),
                                    GetEntryBin = fun F(V) ->
                                        HeightEntryKey = erlang:term_to_binary({?BIN_TO_B58(Key), V}),
                                        case rocksdb:get(DB, CF, HeightEntryKey, []) of
                                            {ok, HeightEntryBin} when V > 0 ->
                                                case erlang:binary_to_term(HeightEntryBin) of
                                                    {EntryHeight, EntryBin} when EntryHeight =< Height ->
                                                        {ok, EntryBin};
                                                    {EntryHeight, _} when EntryHeight > Height ->
                                                        F(V-1)
                                                end;
                                            _ ->
                                                not_found
                                        end
                                    end,
                                    case CF of
                                        EntriesCF ->
                                            case GetEntryBin(Size) of
                                                {ok, EntryBin} ->
                                                    Entry = blockchain_ledger_entry_v1:deserialize(EntryBin),
                                                    #{
                                                        balance => blockchain_ledger_entry_v1:balance(Entry),
                                                        nonce => blockchain_ledger_entry_v1:nonce(Entry)
                                                    };
                                                _ ->
                                                    #{
                                                        balance => 0,
                                                        nonce => 0
                                                    }
                                            end;
                                        DCEntriesCF ->
                                            case GetEntryBin(Size) of
                                                {ok, EntryBin} ->
                                                    Entry = blockchain_ledger_data_credits_entry_v1:deserialize(EntryBin),
                                                    #{
                                                        dc_balance => blockchain_ledger_data_credits_entry_v1:balance(Entry),
                                                        dc_nonce => blockchain_ledger_data_credits_entry_v1:nonce(Entry)
                                                    };
                                                _ ->
                                                #{
                                                        dc_balance => 0,
                                                        dc_nonce => 0
                                                    } 
                                            end;
                                        SecuritiesCF ->
                                            case GetEntryBin(Size) of
                                                {ok, EntryBin} ->
                                                    Entry = blockchain_ledger_security_entry_v1:deserialize(EntryBin),
                                                    #{
                                                        sec_balance => blockchain_ledger_security_entry_v1:balance(Entry),
                                                        sec_nonce => blockchain_ledger_security_entry_v1:nonce(Entry)
                                                    };
                                                _ ->
                                                    #{
                                                        sec_balance => 0,
                                                        sec_nonce => 0
                                                    }
                                            end
                                    end;
                                not_found ->
                                    case CF of
                                        EntriesCF ->
                                            #{
                                                balance => 0,
                                                nonce => 0
                                            };
                                        DCEntriesCF ->
                                            #{
                                                dc_balance => 0,
                                                dc_nonce => 0    
                                            };
                                        SecuritiesCF ->
                                            #{
                                                sec_balance => 0,
                                                sec_nonce => 0
                                            }
                                    end
                            end,
                            maps:merge(Acc, Account)
                        end,
                        #{address => ?BIN_TO_B58(Key), block => Height},
                        [{EntriesCF, EntriesSizeCF}, {DCEntriesCF, DCEntriesSizeCF}, {SecuritiesCF, SecuritiesSizeCF}]
                    )
            end;
        _ ->
            {error, no_historic_balance}
    end.

compact_db(#state{
    db = DB, default = Default,
    entries=EntriesCF,
    dc_entries=DCEntriesCF,
    dc_entries_size=DCEntriesSizeCF,
    securities=SecuritiesCF,
    securities_size=SecuritiesSizeCF,
    entries_size=EntriesSizeCF
}) ->
    rocksdb:compact_range(DB, Default, undefined, undefined, []),
    rocksdb:compact_range(DB, EntriesCF, undefined, undefined, []),
    rocksdb:compact_range(DB, EntriesSizeCF, undefined, undefined, []),
    rocksdb:compact_range(DB, DCEntriesCF, undefined, undefined, []),
    rocksdb:compact_range(DB, DCEntriesSizeCF, undefined, undefined, []),
    rocksdb:compact_range(DB, SecuritiesCF, undefined, undefined, []),
    rocksdb:compact_range(DB, SecuritiesSizeCF, undefined, undefined, []),
    ok.
