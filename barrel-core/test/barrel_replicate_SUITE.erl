%% Copyright 2016, Bernard Notarianni
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

-module(barrel_replicate_SUITE).
-author("Bernard Notarianni").

%% API
-export(
   [
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
   ]).

-export(
   [ one_doc/1
   , target_not_empty/1
   , deleted_doc/1
   , random_activity/1
   ]).

all() ->
  [ one_doc
  , target_not_empty
  , deleted_doc
  , random_activity
  ].

init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(barrel),
  Config.

init_per_testcase(_, Config) ->
  ok = barrel_db:start(<<"testdb">>, barrel_test_rocksdb),
  ok = barrel_db:start(<<"source">>, barrel_test_rocksdb),
  Config.

end_per_testcase(_, _Config) ->
  ok = barrel_db:clean(<<"testdb">>),
  ok = barrel_db:clean(<<"source">>),
  ok.

end_per_suite(Config) ->
  %% TODO this gives an error
  %% {error_db_destroy,
  %%     "IO error: lock testdb/LOCK: No locks available"}}}

  %% ok = erocksdb:destroy("testdb", []),
  %% ok = erocksdb:destroy("source", []),
  Config.


source() ->
  <<"source">>.

target() ->
  <<"testdb">>.

one_doc(_Config) ->
  Options = [{metrics_freq, 100}],
  {ok, _Pid} = barrel_replicate:start_link(source(), target(), Options),
  Doc = #{ <<"_id">> => <<"a">>, <<"v">> => 1},
  {ok, <<"a">>, RevId} = barrel_db:put(<<"source">>, <<"a">>, Doc, []),
  Doc2 = Doc#{<<"_rev">> => RevId},
  timer:sleep(200),
  {ok, Doc2} = barrel_db:get(<<"testdb">>, <<"a">>, []),
  stopped = barrel_replicate:stop(),

  [Stats] = barrel_task_status:all(),
  1 = proplists:get_value(docs_read, Stats),
  1 = proplists:get_value(docs_written, Stats),
  ok.

target_not_empty(_Config) ->
  Doc = #{ <<"_id">> => <<"a">>, <<"v">> => 1},
  {ok, <<"a">>, RevId} = barrel_db:put(<<"source">>, <<"a">>, Doc, []),
  Doc2 = Doc#{<<"_rev">> => RevId},

  {ok, _Pid} = barrel_replicate:start_link(source(), target()),
  timer:sleep(200),

  {ok, Doc2} = barrel_db:get(<<"testdb">>, <<"a">>, []),
  stopped = barrel_replicate:stop(),
  ok.

deleted_doc(_Config) ->
  Doc = #{ <<"_id">> => <<"a">>, <<"v">> => 1},
  {ok, <<"a">>, RevId} = barrel_db:put(<<"source">>, <<"a">>, Doc, []),

  {ok, _Pid} = barrel_replicate:start_link(source(), target()),
  barrel_db:delete(<<"source">>, <<"a">>, RevId, []),
  timer:sleep(200),
  {ok, Doc3} = barrel_db:get(<<"testdb">>, <<"a">>, []),
  true = maps:get(<<"_deleted">>, Doc3),
  stopped = barrel_replicate:stop(),
  ok.

random_activity(_Config) ->
  Scenario = generate_scenario(),
  {ok, _Pid} = barrel_replicate:start_link(source(), target()),
  play_scenario(Scenario),
  timer:sleep(200),
  stopped = barrel_replicate:stop(),
  {ok, DocF1} = barrel_db:get(<<"source">>, <<"f">>, []),
  {ok, DocF2} = barrel_db:get(<<"testdb">>, <<"f">>, []),
  3 = maps:get(<<"v">>, DocF1),
  3 = maps:get(<<"v">>, DocF2),
  ok.

play_scenario(Scenario) ->
  [play(C) || C <- Scenario].

play({put, DocName, Value})->
  put_doc(DocName,Value);
play({del, DocName}) ->
  delete_doc(DocName).

put_doc(DocName, Value) ->
  Id = list_to_binary(DocName),
  case barrel_db:get(<<"source">>, Id, []) of
    {ok, Doc} ->
      Doc2 = Doc#{<<"v">> => Value},
      {ok,_,_} = barrel_db:put(<<"source">>, Id, Doc2, []);
    {error, not_found} ->
      Doc = #{<<"_id">> => Id, <<"v">> => Value},
      {ok,_,_} = barrel_db:put(<<"source">>, Id, Doc, [])
  end.

delete_doc(DocName) ->
  Id = list_to_binary(DocName),
  {ok, Doc} = barrel_db:get(<<"source">>, Id, []),
  RevId = maps:get(<<"_rev">>, Doc),
  barrel_db:delete(<<"source">>, Id, RevId, []).

generate_scenario() ->
  [ {put, "a", 1}
  , {put, "b", 1}
  , {put, "c", 1}
  , {put, "d", 1}
  , {put, "a", 2}
  , {put, "e", 1}
  , {put, "f", 1}
  , {put, "f", 2}
  , {del, "a"}
  , {put, "f", 3}
  ].
