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

-module(barrel_replicate_task).
-author("Bernard Notarianni").

-behaviour(gen_server).

%% specific API
-export([
  start_link/4,
  info/1
]).

%% gen_server API
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

%% internal api
-export([
  replication_key/1,
  clean/2
]).


-record(st, { id          ::binary()  % replication id
            , source
            , target
            , checkpoint              % checkpoint object
            , metrics
            , options
            }).



start_link(Name, Source, Target, Options) ->
  gen_server:start_link(?MODULE, {Name, Source, Target, Options}, []).


info(Pid) when is_pid(Pid)->
  gen_server:call(Pid, info).

clean(_RepId, _Target) ->
  {error, not_implemented}.
  %% RepId = repid(Source, Target),
  %% delete_checkpoint_doc(Source, RepId),
  %% delete_checkpoint_doc(Target, RepId).

replication_key(Name) -> {n, l, {barrel_replicate, Name}}.


%% gen_server callbacks

init({RepId, Source0, Target0, Options}) ->
  process_flag(trap_exit, true),

  {ok, Source} = maybe_connect(Source0),
  {ok, Target} = maybe_connect(Target0),

  Metrics = barrel_metrics:new(),
  Checkpoint = barrel_replicate_checkpoint:new(RepId, Source, Target, Options),
  StartSeq = barrel_replicate_checkpoint:get_start_seq(Checkpoint),

  {ok, LastSeq, Metrics2} = barrel_replicate_alg:replicate(Source, Target, StartSeq, Metrics),
  Checkpoint2 = barrel_replicate_checkpoint:set_last_seq(LastSeq, Checkpoint),
  ok = barrel_event:reg(Source),
  State = #st{id=RepId,
              source=Source,
              target=Target,
              checkpoint=Checkpoint2,
              metrics=Metrics2,
              options=Options},
  ok = barrel_metrics:create_task(Metrics2, Options),
  barrel_metrics:update_task(Metrics2),
  {ok, State}.

handle_call(info, _From, State) ->
  RepId = State#st.id,
  Source = State#st.source,
  Checkpoint = State#st.checkpoint,
  History = case barrel_replicate_checkpoint:read_checkpoint_doc(Source, RepId) of
              {ok, Doc} ->
                maps:get(<<"history">>, Doc);
              _Other ->
                []
            end,
  Info = #{ id => State#st.id
          , source => State#st.source
          , target => State#st.target
          , last_seq => barrel_replicate_checkpoint:get_last_seq(Checkpoint)
          , metrics => State#st.metrics
          , checkpoints => History
          },

  {reply, Info, State};

handle_call(stop, _From, State) ->
  {stop, normal, stopped, State}.

handle_cast(shutdown, State) ->
  {stop, normal, State}.

handle_info({'$barrel_event', _, db_updated}, S) ->
  Source = S#st.source,
  Target = S#st.target,
  Checkpoint = S#st.checkpoint,
  From = barrel_replicate_checkpoint:get_last_seq(Checkpoint),
  Metrics = S#st.metrics,

  {ok, LastSeq, Metrics2} = barrel_replicate_alg:replicate(Source, Target, From, Metrics),
  Checkpoint2 = barrel_replicate_checkpoint:set_last_seq(LastSeq, Checkpoint),
  Checkpoint3 = barrel_replicate_checkpoint:maybe_write_checkpoint(Checkpoint2),

  S2 = S#st{checkpoint=Checkpoint3, metrics=Metrics2},
  barrel_metrics:update_task(Metrics2),
  {noreply, S2}.

%% default gen_server callback
terminate(_Reason, State = #st{id=RepId, source=Source, target=Target}) ->
  barrel_metrics:update_task(State#st.metrics),
  lager:debug(
    "barrel_replicate(~p} terminated: ~p",
    [RepId, _Reason]
  ),
  ok = barrel_replicate_checkpoint:write_checkpoint(State#st.checkpoint),
  ok = barrel_event:unreg(),
  %% close the connections
  [maybe_close(Conn) || Conn <- [Source, Target]],
  ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


%% TODO: check if the backend is registered or the db exists
maybe_connect({Backend, Uri}) -> Backend:connect(Uri, []);
maybe_connect({Backend, Uri, Options}) -> Backend:connect(Uri, Options);
maybe_connect(Db) -> {ok, Db}.

maybe_close({Mod, ModState}) -> Mod:disconnect(ModState);
maybe_close(_) -> ok.

