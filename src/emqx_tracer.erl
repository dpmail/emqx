%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_tracer).

-behaviour(gen_server).

-include("emqx.hrl").

-export([start_link/0]).
-export([trace/2]).
-export([start_trace/2, lookup_traces/0, stop_trace/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {level, org_top_level, traces}).

-type(trace_who() :: {client_id | topic, binary()}).

-define(TRACER, ?MODULE).
-define(FORMAT, {emqx_logger_formatter,
                  #{template =>
                      [time," [",level,"] ",
                       {client_id,
                          [{peername,
                              [client_id,"@",peername," "],
                              [client_id, " "]}],
                          []},
                       msg,"\n"]}}).

-spec(start_link() -> {ok, pid()} | ignore | {error, term()}).
start_link() ->
    gen_server:start_link({local, ?TRACER}, ?MODULE, [], []).

trace(publish, #message{topic = <<"$SYS/", _/binary>>}) ->
    %% Dont' trace '$SYS' publish
    ignore;
trace(publish, #message{from = From, topic = Topic, payload = Payload})
        when is_binary(From); is_atom(From) ->
    emqx_logger:info(#{topic => Topic}, "PUBLISH to ~s: ~p", [Topic, Payload]).

%%------------------------------------------------------------------------------
%% Start/Stop trace
%%------------------------------------------------------------------------------

%% @doc Start to trace client_id or topic.
-spec(start_trace(trace_who(), string()) -> ok | {error, term()}).
start_trace({client_id, ClientId}, LogFile) ->
    start_trace({start_trace, {client_id, ClientId}, LogFile});
start_trace({topic, Topic}, LogFile) ->
    start_trace({start_trace, {topic, Topic}, LogFile}).

start_trace(Req) -> gen_server:call(?MODULE, Req, infinity).

%% @doc Stop tracing client_id or topic.
-spec(stop_trace(trace_who()) -> ok | {error, term()}).
stop_trace({client_id, ClientId}) ->
    gen_server:call(?MODULE, {stop_trace, {client_id, ClientId}});
stop_trace({topic, Topic}) ->
    gen_server:call(?MODULE, {stop_trace, {topic, Topic}}).

%% @doc Lookup all traces
-spec(lookup_traces() -> [{Who :: trace_who(), LogFile :: string()}]).
lookup_traces() ->
    gen_server:call(?TRACER, lookup_traces).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, #state{level = emqx_config:get_env(trace_level, debug),
                org_top_level = get_top_level(),
                traces = #{}}}.

handle_call({start_trace, Who, LogFile}, _From, State = #state{level = Level, traces = Traces}) ->
    case logger:add_handler(handler_id(Who), logger_disk_log_h,
                                #{level => Level,
                                  formatter => ?FORMAT,
                                  filesync_repeat_interval => 1000,
                                  config => #{type => halt, file => LogFile},
                                  filter_default => stop,
                                  filters => [{meta_key_filter,
                                               {fun filter_by_meta_key/2, Who} }]}) of
        ok ->
            set_top_level(all), % open the top logger level to 'all'
            emqx_logger:info("[Tracer] start trace for ~p", [Who]),
            {reply, ok, State#state{traces = maps:put(Who, LogFile, Traces)}};
        {error, Reason} ->
            emqx_logger:error("[Tracer] start trace for ~p failed, error: ~p", [Who, Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call({stop_trace, Who}, _From, State = #state{org_top_level = OrgTopLevel, traces = Traces}) ->
    case maps:find(Who, Traces) of
        {ok, _LogFile} ->
            case logger:remove_handler(handler_id(Who)) of
                ok ->
                    emqx_logger:info("[Tracer] stop trace for ~p", [Who]);
                {error, Reason} ->
                    emqx_logger:error("[Tracer] stop trace for ~p failed, error: ~p", [Who, Reason])
            end,
            set_top_level(OrgTopLevel), % reset the top logger level to original value
            {reply, ok, State#state{traces = maps:remove(Who, Traces)}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(lookup_traces, _From, State = #state{traces = Traces}) ->
    {reply, [{Who, LogFile} || {Who, LogFile} <- maps:to_list(Traces)], State};

handle_call(Req, _From, State) ->
    emqx_logger:error("[Tracer] unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    emqx_logger:error("[Tracer] unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    emqx_logger:error("[Tracer] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handler_id({topic, Topic}) ->
    list_to_atom("topic_" ++ binary_to_list(Topic));
handler_id({client_id, ClientId}) ->
    list_to_atom("clientid_" ++ binary_to_list(ClientId)).

get_top_level() ->
    #{level := OrgTopLevel} = logger:get_primary_config(),
    OrgTopLevel.

set_top_level(Level) ->
    logger:set_primary_config(level, Level).

filter_by_meta_key(#{meta:=Meta}=LogEvent, {MetaKey, MetaValue}) ->
    case maps:find(MetaKey, Meta) of
        {ok, MetaValue} -> LogEvent;
        {ok, Topic} when MetaKey =:= topic ->
            case emqx_topic:match(Topic, MetaValue) of
                true -> LogEvent;
                false -> ignore
            end;
        _ -> ignore
    end.