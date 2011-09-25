#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ./src/couchdb -sasl errlog_type error -boot start_sasl -noshell

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

filename() -> "./test/etap/temp.023".


main(_) ->
    test_util:init_code_path(),
    etap:plan(14),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail()
    end,
    ok.


test() ->
    no_purged_items_test(),
    all_purged_items_test(),
    partial_purges_test(),
    partial_purges_test_with_stop(),
    ok.


no_purged_items_test() ->
    ReduceFun = fun
        (reduce, KVs) -> length(KVs);
        (rereduce, Reds) -> lists:sum(Reds)
    end,

    {ok, Fd} = couch_file:open(filename(), [create, overwrite]),
    {ok, Btree} = couch_btree:open(nil, Fd, [{reduce, ReduceFun}]),

    N = 211341,
    KVs = [{I, I} || I <- lists:seq(1, N)],
    {ok, Btree2} = couch_btree:add_remove(Btree, KVs, []),
    ok = couch_file:flush(Fd),

    {ok, Red} = couch_btree:full_reduce(Btree2),
    etap:is(Red, N, "Initial reduce value equals N"),

    PurgeFun = fun
        (value, _, Acc) ->
            {keep, Acc};
        (branch, _, Acc) ->
            {keep, Acc}
    end,
    {ok, Btree3, Acc1} = couch_btree:guided_purge(Btree2, PurgeFun, []),
    ok = couch_file:flush(Fd),
    etap:is(Acc1, [], "guided_purge returned right accumulator"),
    {ok, Red2} = couch_btree:full_reduce(Btree3),
    etap:is(Red2, N, "Reduce value after guided purge equals N"),

    FoldFun = fun(KV, _, Acc) ->
        {ok, [KV | Acc]}
    end,
    {ok, _, KVs2} = couch_btree:foldl(Btree3, FoldFun, []),
    etap:is(lists:reverse(KVs2), KVs, "Btree has same values after guided purge"),

    couch_file:close(Fd).


all_purged_items_test() ->
    ReduceFun = fun
        (reduce, KVs) -> length(KVs);
        (rereduce, Reds) -> lists:sum(Reds)
    end,

    {ok, Fd} = couch_file:open(filename(), [create, overwrite]),
    {ok, Btree} = couch_btree:open(nil, Fd, [{reduce, ReduceFun}]),

    N = 211341,
    KVs = [{I, I} || I <- lists:seq(1, N)],
    {ok, Btree2} = couch_btree:add_remove(Btree, KVs, []),
    ok = couch_file:flush(Fd),

    {ok, Red} = couch_btree:full_reduce(Btree2),
    etap:is(Red, N, "Initial reduce value equals N"),

    PurgeFun = fun
        (value, _, {V, B}) ->
            {purge, {V + 1, B}};
        (branch, R, {V, B}) ->
            {purge, {V, B + R}}
    end,
    {ok, Btree3, Acc1} = couch_btree:guided_purge(Btree2, PurgeFun, {0, 0}),
    ok = couch_file:flush(Fd),
    etap:is(Acc1, {0, N}, "guided_purge returned right accumulator - {0, N}"),
    {ok, Red2} = couch_btree:full_reduce(Btree3),
    etap:is(Red2, 0, "Reduce value after guided purge equals 0"),

    FoldFun = fun(KV, _, Acc) ->
        {ok, [KV | Acc]}
    end,
    {ok, _, KVs2} = couch_btree:foldl(Btree3, FoldFun, []),
    etap:is(lists:reverse(KVs2), [], "Btree is empty after guided purge"),

    couch_file:close(Fd).


partial_purges_test() ->
    ReduceFun = fun
        (reduce, KVs) ->
            even_odd_count(KVs);
        (rereduce, Reds) ->
            Even = lists:sum([E || {E, _} <- Reds]),
            Odd = lists:sum([O || {_, O} <- Reds]),
            {Even, Odd}
    end,

    {ok, Fd} = couch_file:open(filename(), [create, overwrite]),
    {ok, Btree} = couch_btree:open(nil, Fd, [{reduce, ReduceFun}]),

    N = 211341,
    KVs = [{I, I} || I <- lists:seq(1, N)],
    {NumEven, NumOdds} = even_odd_count(KVs),

    {ok, Btree2} = couch_btree:add_remove(Btree, KVs, []),
    ok = couch_file:flush(Fd),

    {ok, Red} = couch_btree:full_reduce(Btree2),
    etap:is(Red, {NumEven, NumOdds}, "Initial reduce value equals {NumEven, NumOdd}"),

    PurgeFun = fun
        (value, {K, K}, Count) ->
            case (K rem 2) of
            0 ->
                {keep, Count};
            _ ->
                {purge, Count + 1}
            end;
        (branch, {0, _OdCount}, Count) ->
            {purge, Count};
        (branch, {_, 0}, Count) ->
            {keep, Count};
        (branch, {EvCount, _OdCount}, Count) when EvCount > 0 ->
            {partial_purge, Count}
    end,
    {ok, Btree3, Acc1} = couch_btree:guided_purge(Btree2, PurgeFun, 0),
    ok = couch_file:flush(Fd),
    etap:is(Acc1, NumOdds, "guided_purge returned right accumulator - NumOdds}"),
    {ok, Red2} = couch_btree:full_reduce(Btree3),
    etap:is(Red2, {NumEven, 0}, "Reduce value after guided purge equals {NumEven, 0}"),

    FoldFun = fun(KV, _, Acc) ->
        {ok, [KV | Acc]}
    end,
    {ok, _, KVs2} = couch_btree:foldl(Btree3, FoldFun, []),
    lists:foreach(
        fun({K, K}) ->
            case (K rem 2) of
            0 ->
                ok;
            _ ->
                etap:bail("Got odd value in btree after guided purge: " ++ integer_to_list(K))
            end
        end,
        KVs2),
    etap:diag("Btree has no odd values after guided purge"),

    couch_file:close(Fd).


partial_purges_test_with_stop() ->
    ReduceFun = fun
        (reduce, KVs) ->
            even_odd_count(KVs);
        (rereduce, Reds) ->
            Even = lists:sum([E || {E, _} <- Reds]),
            Odd = lists:sum([O || {_, O} <- Reds]),
            {Even, Odd}
    end,

    {ok, Fd} = couch_file:open(filename(), [create, overwrite]),
    {ok, Btree} = couch_btree:open(nil, Fd, [{reduce, ReduceFun}]),

    N = 211341,
    KVs = [{I, I} || I <- lists:seq(1, N)],
    {NumEven, NumOdds} = even_odd_count(KVs),

    {ok, Btree2} = couch_btree:add_remove(Btree, KVs, []),
    ok = couch_file:flush(Fd),

    {ok, Red} = couch_btree:full_reduce(Btree2),
    etap:is(Red, {NumEven, NumOdds}, "Initial reduce value equals {NumEven, NumOdd}"),

    PurgeFun = fun
        (_, _, Count) when Count >= 4 ->
            {stop, Count};
        (value, {K, K}, Count) ->
            case (K rem 2) of
            0 ->
                {keep, Count};
            _ ->
                {purge, Count + 1}
            end;
        (branch, {0, _OdCount}, Count) ->
            {purge, Count};
        (branch, {_, 0}, Count) ->
            {keep, Count};
        (branch, {EvCount, _OdCount}, Count) when EvCount > 0 ->
            {partial_purge, Count}
    end,
    {ok, Btree3, Acc1} = couch_btree:guided_purge(Btree2, PurgeFun, 0),
    ok = couch_file:flush(Fd),
    etap:is(Acc1, 4, "guided_purge returned right accumulator - 4}"),
    {ok, Red2} = couch_btree:full_reduce(Btree3),
    etap:is(Red2, {NumEven, NumOdds - 4}, "Reduce value after guided purge equals {NumEven, NumOdds - 4}"),

    FoldFun = fun(KV, _, Acc) ->
        {ok, [KV | Acc]}
    end,
    {ok, _, KVs2} = couch_btree:foldl(Btree3, FoldFun, []),
    lists:foreach(
        fun({K, K}) ->
            case lists:member(K, [1, 3, 5, 7]) of
            false ->
                ok;
            true ->
                etap:bail("Got odd value <= 7 in btree after guided purge: " ++ integer_to_list(K))
            end
        end,
        KVs2),
    etap:diag("Btree has no odd values after guided purge"),

    couch_file:close(Fd).


even_odd_count(KVs) ->
    Even = lists:sum([1 || {E, _} <- KVs, (E rem 2) =:= 0]),
    Odd = lists:sum([1 || {O, _} <- KVs, (O rem 2) =/= 0]),
    {Even, Odd}.
