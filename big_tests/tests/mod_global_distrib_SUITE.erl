%%==============================================================================
%% Copyright 2017 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(mod_global_distrib_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("exml/include/exml.hrl").

-define(HOSTS_REFRESH_INTERVAL, 200). %% in ms
-define(PROBE_INTERVAL, 1). %% seconds

-import(domain_helper, [domain/0]).
-import(config_parser_helper, [config/2, mod_config/2]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [
     {group, mod_global_distrib},
     {group, cluster_restart},
     {group, start_checks},
     {group, invalidation},
     {group, multi_connection},
     {group, rebalancing},
     {group, advertised_endpoints},
     {group, hosts_refresher}
    ].

groups() ->
    [{mod_global_distrib, [],
          [
           test_pm_between_users_at_different_locations,
           test_pm_between_users_before_available_presence,
           test_component_disconnect,
           test_component_on_one_host,
           test_components_in_different_regions,
           test_hidden_component_disco_in_different_region,
           test_pm_with_disconnection_on_other_server,
           test_pm_with_graceful_reconnection_to_different_server,
           test_pm_with_ungraceful_reconnection_to_different_server,
           test_pm_with_ungraceful_reconnection_to_different_server_with_asia_refreshes_first,
           test_pm_with_ungraceful_reconnection_to_different_server_with_europe_refreshes_first,
           test_component_unregister,
           test_update_senders_host,
           test_update_senders_host_by_ejd_service,

           %% with node 2 disabled
           test_muc_conversation_on_one_host,
           test_instrumentation_events_on_one_host,
           test_global_disco
          ]},
         {hosts_refresher, [],
          [test_host_refreshing]},
         {cluster_restart, [],
          [
           test_location_disconnect
          ]},
         {start_checks, [],
          [
           test_error_on_wrong_hosts
          ]},
         {invalidation, [],
          [
           % TODO: Add checks for other mapping refreshes
           refresh_nodes
          ]},
         {multi_connection, [],
          [
           test_in_order_messages_on_multiple_connections,
           test_in_order_messages_on_multiple_connections_with_bounce,
           test_messages_bounced_in_order,

           %% with node 2 disabled
           test_muc_conversation_history
          ]},
         {rebalancing, [],
          [
           enable_new_endpoint_on_refresh,
           disable_endpoint_on_refresh,
           wait_for_connection,
           closed_connection_is_removed_from_disabled
          ]},
         {advertised_endpoints, [],
          [
           test_advertised_endpoints_override_endpoints,
           test_pm_between_users_at_different_locations
          ]}
    ].

suite() ->
    [{require, europe_node1, {hosts, mim, node}},
     {require, europe_node2, {hosts, mim2, node}},
     {require, asia_node, {hosts, reg, node}},
     {require, c2s_port, {hosts, mim, c2s_port}} |
     escalus:suite()].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    case {rpc(europe_node1, mongoose_wpool, get_worker, [redis, global, global_distrib]),
          rpc(asia_node, mongoose_wpool, get_worker, [redis, global, global_distrib])} of
        {{ok, _}, {ok, _}} ->
            case ct_helper:get_internal_database() of
                mnesia ->
                    ok = rpc(europe_node2, mongoose_cluster, join, [ct:get_config(europe_node1)]);
                _ ->
                    ok
            end,
            enable_logging(),
            instrument_helper:start(events()),
            Config1 = mongoose_helper:backup_and_set_config_option(Config, [instrumentation, probe_interval], ?PROBE_INTERVAL),
            escalus:init_per_suite([{add_advertised_endpoints, []}, {extra_config, #{}} | Config1]);
        Result ->
            ct:pal("Redis check result: ~p", [Result]),
            {skip, "GD Redis default pool not available"}
    end.

events() ->
    % because mod_global_distrib starts instrumentation manually, it doesn't export instrumentation/1
    Specs = rpc(europe_node1, mod_global_distrib, instrumentation, []),
    GDEvents = [{Event, Labels} || {Event, Labels, _Config} <- Specs],
    OtherModules = [mod_global_distrib_bounce, mod_global_distrib_hosts_refresher,
                    mod_global_distrib_mapping, mod_global_distrib_receiver],
    GDEvents ++ lists:append([instrument_helper:declared_events(M) || M <- OtherModules]).

end_per_suite(Config) ->
    disable_logging(),
    escalus_fresh:clean(),
    rpc(europe_node2, mongoose_cluster, leave, []),
    escalus:end_per_suite(Config),
    mongoose_helper:restore_config_option(Config, [instrumentation, probe_interval]),
    instrument_helper:stop().

init_per_group(start_checks, Config) ->
    NodeName = europe_node1,
    NodeSpec = node_spec(NodeName),
    Config1 = dynamic_modules:save_modules(NodeSpec, [domain()], Config),
    dynamic_modules:ensure_modules(NodeSpec, domain(), [{mod_global_distrib, stopped}]),
    Config1;
init_per_group(multi_connection, Config) ->
    ExtraConfig = #{bounce => #{resend_after_ms => 20000},
                    connections => #{%% Disable unused feature to avoid interference
                                     connections_per_endpoint => 100,
                                     disabled_gc_interval => 10000}},
    init_per_group_generic([{extra_config, ExtraConfig} | Config]);
init_per_group(invalidation, Config) ->
    Config1 = init_per_group(invalidation_generic, Config),
    NodeBin = <<"fake_node@localhost">>,
    [{node_to_expire, NodeBin} | Config1];
init_per_group(rebalancing, Config) ->
    %% We need to prevent automatic refreshes, because they may interfere with tests
    %% and we need early disabled garbage collection to check its validity
    ExtraConfig = #{connections => #{endpoint_refresh_interval => 3600,
                                     endpoint_refresh_interval_when_empty => 3600,
                                     disabled_gc_interval => 1},
                    redis => #{refresh_after => 3600}},
    init_per_group_generic([{extra_config, ExtraConfig} | Config]);
init_per_group(advertised_endpoints, Config) ->
    lists:foreach(fun({NodeName, _, _}) ->
                          Node = ct:get_config(NodeName),
                          mongoose_helper:inject_module(#{node => Node}, ?MODULE, reload)
                  end, get_hosts()),
    mock_inet_on_each_node(),
    init_per_group_generic(
               [{add_advertised_endpoints,
                 [{asia_node, advertised_endpoints()}]} | Config]);
init_per_group(mod_global_distrib, Config) ->
    %% Disable mod_global_distrib_mapping_redis refresher
    ExtraConfig = #{redis => #{refresh_after => 3600}},
    init_per_group_generic([{extra_config, ExtraConfig} | Config]);
init_per_group(_, Config) ->
    init_per_group_generic(Config).

init_per_group_generic(Config0) ->
    Config2 = lists:foldl(fun init_modules_per_node/2, Config0, get_hosts()),
    wait_for_listeners_to_appear(),
    {SomeNode, _, _} = hd(get_hosts()),
    NodesKey = rpc(SomeNode, mod_global_distrib_mapping_redis, nodes_key, []),
    [{nodes_key, NodesKey}, {escalus_user_db, xmpp} | Config2].

init_modules_per_node({NodeName, LocalHost, ReceiverPort}, Config0) ->
    Extra0 = module_opts(?config(extra_config, Config0)),
    EndpointOpts = endpoint_opts(NodeName, ReceiverPort, Config0),
    ConnExtra = maps:merge(EndpointOpts, maps:get(connections, Extra0, #{})),
    Extra = Extra0#{local_host => LocalHost, connections => ConnExtra},
    Opts = module_opts(Extra),

    VirtHosts = virtual_hosts(NodeName),
    Node = node_spec(NodeName),
    Config1 = dynamic_modules:save_modules(Node, VirtHosts, Config0),

    %% To reduce load when sending many messages
    ModulesToStop = [mod_offline, mod_blocking, mod_privacy, mod_roster, mod_last,
                     mod_stream_management],
    [dynamic_modules:ensure_stopped(Node, VirtHost, ModulesToStop) || VirtHost <- VirtHosts],

    SMBackend = ct_helper:get_internal_database(),
    SMOpts = config_parser_helper:mod_config(mod_stream_management,
                                             #{resume_timeout => 1, backend => SMBackend}),
    dynamic_modules:ensure_modules(Node, domain(), [{mod_global_distrib, Opts},
                                                    {mod_stream_management, SMOpts}]),
    Config1.

module_opts(ExtraOpts) ->
    lists:foldl(fun set_opts/2, ExtraOpts, [common, defaults, connections, redis, bounce]).

set_opts(common, Opts) ->
    maps:merge(#{global_host => <<"localhost">>,
                 hosts_refresh_interval => ?HOSTS_REFRESH_INTERVAL}, Opts);
set_opts(defaults, Opts) ->
    mod_config(mod_global_distrib, Opts);
set_opts(connections, #{connections := ConnExtra} = Opts) ->
    TLSOpts = config([modules, mod_global_distrib, connections, tls],
                     #{certfile => "priv/ssl/fake_server.pem",
                       cacertfile => "priv/ssl/cacert.pem"}),
    Opts#{connections := config([modules, mod_global_distrib, connections],
                                maps:merge(#{tls => TLSOpts}, ConnExtra))};
set_opts(redis, #{redis := RedisExtra} = Opts) ->
    Opts#{redis := config([modules, mod_global_distrib, redis], RedisExtra)};
set_opts(bounce, #{bounce := BounceExtra} = Opts) ->
    Opts#{bounce := config([modules, mod_global_distrib, bounce], BounceExtra)};
set_opts(_, Opts) ->
    Opts.

end_per_group(advertised_endpoints, Config) ->
    Pids = ?config(meck_handlers, Config),
    unmock_inet(Pids),
    escalus_fresh:clean(),
    end_per_group_generic(Config);
end_per_group(start_checks, Config) ->
    escalus_fresh:clean(),
    Config;
end_per_group(invalidation, Config) ->
    redis_query(europe_node1, [<<"HDEL">>, ?config(nodes_key, Config),
                            ?config(node_to_expire, Config)]),
    end_per_group_generic(Config);
end_per_group(_, Config) ->
    end_per_group_generic(Config).

end_per_group_generic(Config) ->
    dynamic_modules:restore_modules(#{timeout => timer:seconds(30)}, Config).

init_per_testcase(CaseName, Config)
  when CaseName == test_muc_conversation_on_one_host; CaseName == test_instrumentation_events_on_one_host;
       CaseName == test_global_disco; CaseName == test_muc_conversation_history ->
    %% There is no helper to load MUC, or count instrumentation events on node2
    %% For now it's easier to hide node2
    %% TODO: Do it right at some point!
    hide_node(europe_node2, Config),
    %% There would be no new connections to europe_node2, but there can be some old ones.
    %% We need to disconnect previous connections.
    {_, EuropeHost, _} = lists:keyfind(europe_node1, 1, get_hosts()),
    trigger_rebalance(asia_node, EuropeHost),
    %% Load muc on mim node
    muc_helper:load_muc(),
    RegNode = ct:get_config({hosts, reg, node}),
    %% Wait for muc.localhost to become visible from reg node
    wait_for_domain(RegNode, muc_helper:muc_host()),
    escalus:init_per_testcase(CaseName, Config);
init_per_testcase(CN, Config) when CN == test_pm_with_graceful_reconnection_to_different_server;
                                   CN == test_pm_with_ungraceful_reconnection_to_different_server;
                                   CN == test_pm_with_ungraceful_reconnection_to_different_server_with_asia_refreshes_first;
                                   CN == test_pm_with_ungraceful_reconnection_to_different_server_with_europe_refreshes_first ->
    escalus:init_per_testcase(CN, init_user_eve(Config));
init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

init_user_eve(Config) ->
    %% Register Eve in reg cluster
    EveSpec = escalus_fresh:create_fresh_user(Config, eve),
    MimPort = ct:get_config({hosts, mim, c2s_port}),
    EveSpec2 = lists:keystore(port, 1, EveSpec, {port, MimPort}),
    %% Register Eve in mim cluster
    escalus:create_users(Config, [{eve, EveSpec2}]),
    [{evespec_reg, EveSpec}, {evespec_mim, EveSpec2} | Config].

end_per_testcase(CN, Config) when CN == test_pm_with_graceful_reconnection_to_different_server;
                                  CN == test_pm_with_ungraceful_reconnection_to_different_server;
                                  CN == test_pm_with_ungraceful_reconnection_to_different_server_with_asia_refreshes_first;
                                  CN == test_pm_with_ungraceful_reconnection_to_different_server_with_europe_refreshes_first ->
    MimEveSpec = ?config(evespec_mim, Config),
    %% Clean Eve from reg cluster
    escalus_fresh:clean(),
    %% Clean Eve from mim cluster
    %% For shared databases (i.e. mysql, pgsql...),
    %% removing from one cluster would remove from all clusters.
    %% For mnesia auth backend we need to call removal from each cluster.
    %% That's why there is a catch here.
    catch escalus_users:delete_users(Config, [{mim_eve, MimEveSpec}]),
    generic_end_per_testcase(CN, Config);
end_per_testcase(CaseName, Config)
  when CaseName == test_muc_conversation_on_one_host; CaseName == test_instrumentation_events_on_one_host;
       CaseName == test_global_disco; CaseName == test_muc_conversation_history ->
    refresh_mappings(europe_node2, "by_end_per_testcase,testcase=" ++ atom_to_list(CaseName)),
    muc_helper:unload_muc(),
    generic_end_per_testcase(CaseName, Config);
end_per_testcase(test_update_senders_host_by_ejd_service = CN, Config) ->
    refresh_mappings(europe_node1, "by_end_per_testcase,testcase=" ++ atom_to_list(CN)),
    generic_end_per_testcase(CN, Config);
end_per_testcase(CN, Config) when CN == enable_new_endpoint_on_refresh;
                                  CN == disable_endpoint_on_refresh;
                                  CN == wait_for_connection;
                                  CN == closed_connection_is_removed_from_disabled ->
    restart_receiver(asia_node),
    refresh_mappings(asia_node, "by_end_per_testcase,testcase=" ++ atom_to_list(CN)),
    generic_end_per_testcase(CN, Config);
end_per_testcase(CaseName, Config) ->
    generic_end_per_testcase(CaseName, Config).

generic_end_per_testcase(CaseName, Config) ->
    lists:foreach(
      fun({NodeName, _, _}) ->
              %% TODO: Enable refresher only for specific test cases,
              %% as some of them are based on assumption that node(s)
              %% must open new connections during tests.
              pause_refresher(NodeName, CaseName),
              Node = ct:get_config(NodeName),
              SupRef = {mod_global_distrib_outgoing_conns_sup, Node},
              try
                  OutgoingConns = supervisor:which_children(SupRef),
                  lists:foreach(fun ({mod_global_distrib_hosts_refresher, _, _, _}) ->
                                        skip;
                                    ({Id, _, _, _}) ->
                                        supervisor:terminate_child(SupRef, Id)
                                end, OutgoingConns),
                  [{mod_global_distrib_hosts_refresher, _, worker, _Modules}] =
                    supervisor:which_children(SupRef)
              catch
                  _:{noproc, _} ->
                      ct:pal("Sender supervisor not found in ~p", [NodeName])
              end,
              unpause_refresher(NodeName, CaseName)
      end,
      get_hosts()),
    escalus:end_per_testcase(CaseName, Config).

virtual_hosts(asia_node) ->
    [domain()];
virtual_hosts(_) ->
    [domain(), secondary_domain()].

secondary_domain() ->
    ct:get_config({hosts, mim, secondary_domain}).

%% Refresher is not started at all or stopped for some test cases
-spec pause_refresher(NodeName :: atom(), CaseName :: atom()) -> ok.
pause_refresher(_, test_error_on_wrong_hosts) ->
    ok;
pause_refresher(asia_node, test_location_disconnect) ->
    ok;
pause_refresher(NodeName, _) ->
    ok = rpc(NodeName, mod_global_distrib_hosts_refresher, pause, []).

-spec unpause_refresher(NodeName :: atom(), CaseName :: atom()) -> ok.
unpause_refresher(_, test_error_on_wrong_hosts) ->
    ok;
unpause_refresher(asia_node, test_location_disconnect) ->
    ok;
unpause_refresher(NodeName, _) ->
    ok = rpc(NodeName, mod_global_distrib_hosts_refresher, unpause, []).

%%--------------------------------------------------------------------
%% Service discovery test
%%--------------------------------------------------------------------

%% Requires module mod_global_distrib to be started with argument advertised_endpoints
%% for each host in get_hosts().
%% Reads Redis to confirm that endpoints (in Redis) are overwritten
%% with `advertised_endpoints` option value
test_advertised_endpoints_override_endpoints(_Config) ->
    Endps = execute_on_each_node(mod_global_distrib_mapping_redis, get_endpoints, [<<"reg1">>]),
    true = lists:all(
             fun(E) ->
                     lists:sort(E) =:= lists:sort(advertised_endpoints())
             end, Endps).

%% @doc Verifies that hosts refresher will restart the outgoing connection pool if
%% it goes down for some reason (crash or domain unavailability).
%% Also actually verifies that refresher properly reads host list
%% from backend and starts appropriate pool.
test_host_refreshing(_Config) ->
    wait_helper:wait_until(fun() -> trees_for_connections_present() end, true,
                           #{name => trees_for_connections_present,
                             time_left => timer:seconds(10)}),
    ConnectionSups = out_connection_sups(asia_node),
    {europe_node1, EuropeHost, _} = lists:keyfind(europe_node1, 1, get_hosts()),
    EuropeSup = rpc(asia_node, mod_global_distrib_utils, server_to_sup_name, [EuropeHost]),
    {_, EuropePid, supervisor, _} = lists:keyfind(EuropeSup, 1, ConnectionSups),
    erlang:exit(EuropePid, kill), % it's ok to kill temporary process
    wait_helper:wait_until(fun() -> tree_for_sup_present(asia_node, EuropeSup) end, true,
                           #{name => tree_for_sup_present}).

%% When run in mod_global_distrib group - tests simple case of connection
%% between two users connected to different clusters.
%% When run in advertised_endpoints group it tests whether it is possible
%% to connect to a node that is advertising itself with a domain name.
test_pm_between_users_at_different_locations(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {eve, 1}], fun test_two_way_pm/2).

test_pm_between_users_before_available_presence(Config) ->
    Config1 = escalus_fresh:create_users(Config, [{alice, 1}, {eve, 1}]),
    {ok, Alice} = escalus_client:start(Config1, alice, <<"res1">>),
    {ok, Eve} = escalus_client:start(Config1, eve, <<"res1">>),

    test_two_way_pm(Alice, Eve),

    escalus_client:stop(Config1, Alice),
    escalus_client:stop(Config1, Eve).

test_two_way_pm(Alice, Eve) ->
    escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"Hi to Eve from Europe1!">>)),
    escalus_client:send(Eve, escalus_stanza:chat_to(Alice, <<"Hi to Alice from Asia!">>)),

    FromAlice = escalus_client:wait_for_stanza(Eve, timer:seconds(15)),
    FromEve = escalus_client:wait_for_stanza(Alice, timer:seconds(15)),

    AliceJid = escalus_client:full_jid(Alice),
    EveJid = escalus_client:full_jid(Eve),

    escalus:assert(is_chat_message_from_to, [AliceJid, EveJid, <<"Hi to Eve from Europe1!">>],
                   FromAlice),
    escalus:assert(is_chat_message_from_to, [EveJid, AliceJid, <<"Hi to Alice from Asia!">>],
                   FromEve),

    instrument_helper:assert(
      mod_global_distrib_mapping_cache_misses, #{},
      fun(#{count := 1, jid := Jid}) -> Jid =:= EveJid end),
    instrument_helper:assert(
      mod_global_distrib_mapping_fetches, #{},
      fun(#{count := 1, time := T, jid := Jid}) ->
              Jid =:= jid:to_lower(jid:from_binary(EveJid)) andalso T >= 0
      end),
    instrument_helper:assert(
      mod_global_distrib_outgoing_established, #{},
      fun(#{count := 1, host := <<"reg1">>}) -> true end),
    instrument_helper:assert(
      mod_global_distrib_outgoing_queue, #{},
      fun(#{time := Time, host := <<"reg1">>}) -> Time >= 0 end),
    instrument_helper:assert(
      mod_global_distrib_outgoing_messages, #{},
      fun(#{count := 1, host := <<"reg1">>}) -> true end).

test_muc_conversation_on_one_host(Config0) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config0, alice),
    Config = muc_helper:given_fresh_room(Config0, AliceSpec, []),
    escalus:fresh_story(
      Config, [{eve, 1}],
      fun(Eve) ->
              Alice = connect_from_spec(AliceSpec, Config),

              RoomJid = ?config(room, Config),
              AliceUsername = escalus_utils:get_username(Alice),
              EveUsername = escalus_utils:get_username(Eve),
              RoomAddr = muc_helper:room_address(RoomJid),

              escalus:send(Alice, muc_helper:stanza_muc_enter_room(RoomJid, AliceUsername)),
              wait_for_muc_presence(Alice, RoomJid, AliceUsername),
              wait_for_subject(Alice),

              escalus:send(Eve, muc_helper:stanza_muc_enter_room(RoomJid, EveUsername)),
              wait_for_muc_presence(Eve, RoomJid, AliceUsername),
              wait_for_muc_presence(Eve, RoomJid, EveUsername),
              wait_for_muc_presence(Alice, RoomJid, EveUsername),
              wait_for_subject(Eve),

              Msg= <<"Hi, Eve!">>,
              escalus:send(Alice, escalus_stanza:groupchat_to(RoomAddr, Msg)),
              escalus:assert(is_groupchat_message, [Msg], escalus:wait_for_stanza(Alice)),
              escalus:assert(is_groupchat_message, [Msg], escalus:wait_for_stanza(Eve)),

              Msg2= <<"Hi, Alice!">>,
              escalus:send(Eve, escalus_stanza:groupchat_to(RoomAddr, Msg2)),
              escalus:assert(is_groupchat_message, [Msg2], escalus:wait_for_stanza(Eve)),
              escalus:assert(is_groupchat_message, [Msg2], escalus:wait_for_stanza(Alice))
      end),
    muc_helper:destroy_room(Config).

test_instrumentation_events_on_one_host(Config) ->
    % testing is done with mim1 and reg1, and without mim2, so that we don't miss any events that could have been
    % emitted there
    Config1 = escalus_fresh:create_users(Config, [{alice, 1}, {eve, 1}]),
    {ok, Alice} = escalus_client:start(Config1, alice, <<"res1">>),
    {ok, Eve} = escalus_client:start(Config1, eve, <<"res1">>),

    test_two_way_pm(Alice, Eve),

    Host = <<"localhost.bis">>,
    instrument_helper:assert(mod_global_distrib_incoming_established, #{},
                             fun(#{count := 1, peer := _}) -> true end),
    instrument_helper:assert(mod_global_distrib_incoming_first_packet, #{},
                             fun(#{count := 1, host := H}) -> H =:= Host end),
    instrument_helper:assert(mod_global_distrib_incoming_transfer, #{},
                             fun(#{time := T, host := H}) when T >= 0 -> H =:= Host end),
    instrument_helper:assert(mod_global_distrib_incoming_messages, #{},
                             fun(#{count := 1, host := H}) -> H =:= Host end),
    instrument_helper:assert(mod_global_distrib_incoming_queue, #{},
                             fun(#{time := T, host := H}) when T >= 0 -> H =:= Host end),

    escalus_client:stop(Config1, Alice),
    escalus_client:stop(Config1, Eve),

    CheckF = fun(#{count := C, host := H}) -> C =:= 1 andalso H =:= Host end,
    instrument_helper:wait_and_assert(mod_global_distrib_incoming_closed, #{}, CheckF).

test_muc_conversation_history(Config0) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config0, alice),
    Config = muc_helper:given_fresh_room(Config0, AliceSpec, []),
    escalus:fresh_story(
      Config, [{eve, 1}],
      fun(Eve) ->
              Alice = connect_from_spec(AliceSpec, Config),

              RoomJid = ?config(room, Config),
              AliceUsername = escalus_utils:get_username(Alice),
              RoomAddr = muc_helper:room_address(RoomJid),

              escalus:send(Alice, muc_helper:stanza_muc_enter_room(RoomJid, AliceUsername)),
              wait_for_muc_presence(Alice, RoomJid, AliceUsername),
              wait_for_subject(Alice),

              send_n_muc_messages(Alice, RoomAddr, 3),

              %% Ensure that the messages are received by the room
              %% before trying to login Eve.
              %% Otherwise, Eve would receive some messages from history and
              %% some as regular groupchat messages.
              receive_n_muc_messages(Alice, 3),

              EveUsername = escalus_utils:get_username(Eve),
              escalus:send(Eve, muc_helper:stanza_muc_enter_room(RoomJid, EveUsername)),

              wait_for_muc_presence(Eve, RoomJid, AliceUsername),
              wait_for_muc_presence(Eve, RoomJid, EveUsername),
              wait_for_muc_presence(Alice, RoomJid, EveUsername),

              %% XEP-0045: After sending the presence broadcast (and only after doing so),
              %% the service MAY then send discussion history, the room subject,
              %% live messages, presence updates, and other in-room traffic.
              receive_n_muc_messages(Eve, 3),
              wait_for_subject(Eve),

              % events are checked only on mim host, the other event was executed on Eve's reg ("asia_node") host
              EveJid = escalus_client:full_jid(Eve),
              instrument_helper:assert_one(mod_global_distrib_delivered_with_ttl, #{},
                                           fun(#{value := TTL, from := From}) ->
                                                   ?assert(TTL > 0), jid:to_binary(From) =:= EveJid
                                           end)
      end),
    muc_helper:destroy_room(Config).

wait_for_muc_presence(User, RoomJid, FromNickname) ->
    Presence = escalus:wait_for_stanza(User),
    escalus:assert(is_presence, Presence),
    escalus:assert(is_stanza_from, [muc_helper:room_address(RoomJid, FromNickname)], Presence),
    ok.

wait_for_subject(User) ->
    Subject = escalus:wait_for_stanza(User),
    escalus:assert(is_groupchat_message, Subject),
    ?assertNotEqual(undefined, exml_query:subelement(Subject, <<"subject">>)),
    ok.

send_n_muc_messages(User, RoomAddr, N) ->
    lists:foreach(fun(I) ->
                          Msg = <<"test-", (integer_to_binary(I))/binary>>,
                          escalus:send(User, escalus_stanza:groupchat_to(RoomAddr, Msg))
                  end, lists:seq(1, N)).

receive_n_muc_messages(User, N) ->
    lists:foreach(fun(J) ->
                          Msg = <<"test-", (integer_to_binary(J))/binary>>,
                          Stanza = escalus:wait_for_stanza(User),
                          escalus:assert(is_groupchat_message, [Msg], Stanza)
                            end, lists:seq(1, N)).

test_component_on_one_host(Config) ->
    ComponentConfig = [{server, <<"localhost">>}, {host, <<"localhost">>}, {password, <<"secret">>},
                       {port, component_port()}, {component, <<"test_service">>}],

    {Comp, Addr, _Name} = component_helper:connect_component(ComponentConfig),

    Story = fun(User) ->
                    Msg1 = escalus_stanza:chat_to(Addr, <<"Hi2!">>),
                    escalus:send(User, Msg1),
                    %% Then component receives it
                    Reply1 = escalus:wait_for_stanza(Comp),
                    escalus:assert(is_chat_message, [<<"Hi2!">>], Reply1),

                    %% When components sends a reply
                    Msg2 = escalus_stanza:chat_to(User, <<"Oh hi!">>),
                    escalus:send(Comp, escalus_stanza:from(Msg2, Addr)),

                    %% Then Alice receives it
                    Reply2 = escalus:wait_for_stanza(User),
                    escalus:assert(is_chat_message, [<<"Oh hi!">>], Reply2),
                    escalus:assert(is_stanza_from, [Addr], Reply2)
            end,

    [escalus:fresh_story(Config, [{User, 1}], Story) || User <- [alice, eve]].

%% Ensures that 2 components in distinct data centers can communicate.
test_components_in_different_regions(_Config) ->
    ComponentCommonConfig = [{host, <<"localhost">>}, {password, <<"secret">>},
                             {server, <<"localhost">>}, {component, <<"test_service">>}],
    Comp1Port = ct:get_config({hosts, mim, component_port}),
    Comp2Port = ct:get_config({hosts, reg, component_port}),
    Component1Config = [{port, Comp1Port}, {component, <<"service1">>} | ComponentCommonConfig],
    Component2Config = [{port, Comp2Port}, {component, <<"service2">>} | ComponentCommonConfig],

    {Comp1, Addr1, _Name1} = component_helper:connect_component(Component1Config),
    {Comp2, Addr2, _Name2} = component_helper:connect_component(Component2Config),

    Msg1 = escalus_stanza:from(escalus_stanza:chat_to(Addr2, <<"Hi from 1!">>), Addr1),
    escalus:send(Comp1, Msg1),
    GotMsg1 = escalus:wait_for_stanza(Comp2),
    escalus:assert(is_chat_message, [<<"Hi from 1!">>], GotMsg1),

    Msg2 = escalus_stanza:from(escalus_stanza:chat_to(Addr1, <<"Hi from 2!">>), Addr2),
    escalus:send(Comp2, Msg2),
    GotMsg2 = escalus:wait_for_stanza(Comp1),
    escalus:assert(is_chat_message, [<<"Hi from 2!">>], GotMsg2).

%% Ordinary user is not able to discover the hidden component from GD
test_hidden_component_disco_in_different_region(Config) ->
    %% Hidden component from component_SUITE connects to mim1/europe_node1
    HiddenComponentConfig = component_helper:spec(hidden_component),
    {_HiddenComp, HiddenAddr, _} = component_helper:connect_component(HiddenComponentConfig),

    escalus:fresh_story(
      Config, [{eve, 1}],
      fun(Eve) ->
              EveServer = escalus_client:server(Eve),
              escalus:send(Eve, escalus_stanza:service_discovery(EveServer)),
              DiscoReply = escalus:wait_for_stanza(Eve),
              escalus:assert(is_iq_result, DiscoReply),
              escalus:assert(fun(Stanza) ->
                                     not escalus_pred:has_service(HiddenAddr, Stanza)
                             end, DiscoReply)
      end).

test_component_disconnect(Config) ->
    ComponentConfig = [{server, <<"localhost">>}, {host, <<"localhost">>}, {password, <<"secret">>},
                       {port, component_port()}, {component, <<"test_service">>}],

    {Comp, Addr, _Name} = component_helper:connect_component(ComponentConfig),
    component_helper:disconnect_component(Comp, Addr),

    Story = fun(User) ->
                    escalus:send(User, escalus_stanza:chat_to(Addr, <<"Hi!">>)),
                    Error = escalus:wait_for_stanza(User, 5000),
                    escalus:assert(is_error, [<<"cancel">>, <<"service-unavailable">>], Error),
                    instrument_helper:assert(mod_global_distrib_outgoing_closed, #{},
                                             fun(#{count := 1, host := <<"reg1">>}) -> true end)
            end,

    AliceStory = fun(User) ->
        Story(User),
        % only check Alice, because Eve's event is executed on other node
        Jid = escalus_client:full_jid(User),
        CheckF = fun(#{count := 1, from := From}) -> jid:to_binary(From) =:= Jid end,
        instrument_helper:assert_one(mod_global_distrib_stop_ttl_zero, #{}, CheckF)
                 end,

    escalus:fresh_story(Config, [{alice, 1}], AliceStory),
    escalus:fresh_story(Config, [{eve, 1}], Story).

test_location_disconnect(Config) ->
    try
        escalus:fresh_story(
          Config, [{alice, 1}, {eve, 1}, {adam, 1}],
          fun(Alice, Eve, Adam) ->
                  escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"Hi from Europe1!">>)),
                  escalus_client:wait_for_stanza(Eve),

                  escalus_client:send(Alice, escalus_stanza:chat_to(Adam, <<"Hi, Adam, from Europe1!">>)),
                  escalus_client:wait_for_stanza(Adam),

                  print_sessions_debug_info(asia_node),
                  ok = rpc(asia_node, application, stop, [mongooseim]),
                  %% TODO: Stopping mongooseim alone should probably stop connections too
                  ok = rpc(asia_node, application, stop, [ranch]),

                  escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"Hi again!">>)),
                  Error = escalus:wait_for_stanza(Alice),
                  escalus:assert(is_error, [<<"cancel">>, <<"service-unavailable">>], Error),

                  escalus_client:send(Alice, escalus_stanza:chat_to(Adam, <<"Hi, Adam, again!">>)),
                  Error2 = escalus:wait_for_stanza(Alice),
                  escalus:assert(is_error, [<<"cancel">>, <<"service-unavailable">>], Error2)
          end)
    after
        rpc(asia_node, application, start, [ranch]),
        rpc(asia_node, application, start, [mongooseim])
    end.

test_pm_with_disconnection_on_other_server(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              escalus_connection:stop(Eve),
              escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"Hi from Europe1!">>)),
              FromAliceBounce = escalus_client:wait_for_stanza(Alice, 15000),
              escalus:assert(is_error, [<<"cancel">>, <<"service-unavailable">>], FromAliceBounce)
      end).

test_pm_with_graceful_reconnection_to_different_server(Config) ->
    EveSpec = ?config(evespec_reg, Config),
    EveSpec2 = ?config(evespec_mim, Config),
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              Eve = connect_from_spec(EveSpec, Config),

              escalus_client:send(Eve, escalus_stanza:chat_to(Alice, <<"Hi from Asia!">>)),

              %% Stop connection and wait for process to die
              EveNode = ct:get_config({hosts, reg, node}),
              mongoose_helper:logout_user(Config, Eve, #{node => EveNode}),

              FromEve = escalus_client:wait_for_stanza(Alice),

              %% Pause Alice until Eve is reconnected
              AliceNode = ct:get_config({hosts, mim, node}),
              C2sPid = mongoose_helper:get_session_pid(Alice, #{node => AliceNode}),
              ok = rpc:call(node(C2sPid), sys, suspend, [C2sPid]),

              escalus_client:send(Alice, chat_with_seqnum(Eve, <<"Hi from Europe1!">>)),

              NewEve = connect_from_spec(EveSpec2, Config),

              ok = rpc:call(node(C2sPid), sys, resume, [C2sPid]),


              escalus_client:send(Alice, chat_with_seqnum(Eve, <<"Hi again from Europe1!">>)),
              escalus_client:send(NewEve, escalus_stanza:chat_to(Alice, <<"Hi again from Asia!">>)),

              FirstFromAlice = escalus_client:wait_for_stanza(NewEve),
              AgainFromEve = escalus_client:wait_for_stanza(Alice),
              SecondFromAlice = escalus_client:wait_for_stanza(NewEve),

              [FromAlice, AgainFromAlice] = order_by_seqnum([FirstFromAlice, SecondFromAlice]),

              escalus:assert(is_chat_message, [<<"Hi from Europe1!">>], FromAlice),
              escalus:assert(is_chat_message, [<<"Hi from Asia!">>], FromEve),
              escalus:assert(is_chat_message, [<<"Hi again from Europe1!">>], AgainFromAlice),
              escalus:assert(is_chat_message, [<<"Hi again from Asia!">>], AgainFromEve)
          end).

%% Refresh logic can cause two possible behaviours.
%% We test both behaviours here (plus no refresh case)
%% See PR #2392
test_pm_with_ungraceful_reconnection_to_different_server(Config) ->
    %% No refresh
    BeforeResume = fun() -> ok end,
    AfterCheck = fun(Alice, NewEve) ->
            user_receives(NewEve, [<<"Hi from Europe1!">>, <<"Hi again from Europe1!">>]),
            user_receives(Alice, [<<"Hi from Europe!">>])
         end,
    do_test_pm_with_ungraceful_reconnection_to_different_server(Config, BeforeResume, AfterCheck).

test_pm_with_ungraceful_reconnection_to_different_server_with_asia_refreshes_first(Config) ->
    %% Same as no refresh
    RefreshReason = "by_test_pm_with_ungraceful_reconnection_to_different_server_with_asia_refreshes_first",
    % Order of nodes is important here in refresh_hosts!
    BeforeResume = fun() -> refresh_hosts([asia_node, europe_node1], RefreshReason) end,
    AfterCheck = fun(Alice, NewEve) ->
            user_receives(NewEve, [<<"Hi from Europe1!">>, <<"Hi again from Europe1!">>]),
            user_receives(Alice, [<<"Hi from Europe!">>])
         end,
    do_test_pm_with_ungraceful_reconnection_to_different_server(Config, BeforeResume, AfterCheck).

test_pm_with_ungraceful_reconnection_to_different_server_with_europe_refreshes_first(Config) ->
    %% Asia node overrides Europe value with the older ones,
    %% so we loose some messages during rerouting :(
    RefreshReason = "by_test_pm_with_ungraceful_reconnection_to_different_server_with_europe_refreshes_first",
    BeforeResume = fun() -> refresh_hosts([europe_node1, asia_node], RefreshReason) end,
    AfterCheck = fun(Alice, NewEve) ->
            user_receives(NewEve, [<<"Hi again from Europe1!">>]),
            user_receives(Alice, [<<"Hi from Europe!">>])
         end,
    do_test_pm_with_ungraceful_reconnection_to_different_server(Config, BeforeResume, AfterCheck).

%% Reconnect Eve from asia (reg cluster) to europe (mim)
do_test_pm_with_ungraceful_reconnection_to_different_server(Config0, BeforeResume, AfterCheck) ->
    Config = escalus_users:update_userspec(Config0, eve, stream_management, true),
    EveSpec = ?config(evespec_reg, Config),
    EveSpec2 = ?config(evespec_mim, Config),
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              {ok, Eve, _} = escalus_connection:start(EveSpec, connect_steps_with_sm()),
              escalus_story:send_initial_presence(Eve),
              escalus_client:wait_for_stanza(Eve),

              %% Stop connection and wait for process to die
              EveNode = ct:get_config({hosts, reg, node}),
              C2sPid = mongoose_helper:get_session_pid(Eve, #{node => EveNode}),
              ok = rpc(asia_node, sys, suspend, [C2sPid]),

              escalus_client:send(Alice, chat_with_seqnum(bare_client(Eve), <<"Hi from Europe1!">>)),

              %% Wait for route message to be queued in c2s message queue
              mongoose_helper:wait_for_route_message_count(C2sPid, 1),

              %% Time to do bad nasty things with our socket, so once our process wakes up,
              %% it SHOULD detect a dead socket
              escalus_connection:kill(Eve),

              %% Connect another one, we hope the message would be rerouted
              NewEve = connect_from_spec(EveSpec2, Config),

              BeforeResume(),

              %% Trigger rerouting
              ok = rpc(asia_node, sys, resume, [C2sPid]),

              %% Let C2sPid to process the message and reroute (and die finally, poor little thing)
              mongoose_helper:wait_for_pid_to_die(C2sPid),

              escalus_client:send(Alice, chat_with_seqnum(bare_client(Eve), <<"Hi again from Europe1!">>)),
              escalus_client:send(NewEve, escalus_stanza:chat_to(Alice, <<"Hi from Europe!">>)),

              AfterCheck(Alice, NewEve)
          end).

test_global_disco(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              AliceServer = escalus_client:server(Alice),
              escalus:send(Alice, escalus_stanza:service_discovery(AliceServer)),
              _AliceStanza = escalus:wait_for_stanza(Alice),
              %% TODO: test for duplicate components
              %%escalus:assert(fun has_exactly_one_service/2, [muc_helper:muc_host()], AliceStanza),

              EveServer = escalus_client:server(Eve),
              escalus:send(Eve, escalus_stanza:service_discovery(EveServer)),
              EveStanza = escalus:wait_for_stanza(Eve),
              escalus:assert(has_service, [muc_helper:muc_host()], EveStanza)
      end).

test_component_unregister(_Config) ->
    ComponentConfig = [{server, <<"localhost">>}, {host, <<"localhost">>}, {password, <<"secret">>},
                       {port, component_port()}, {component, <<"test_service">>}],

    {Comp, Addr, _Name} = component_helper:connect_component(ComponentConfig),
    ?assertMatch({ok, _}, rpc(europe_node1, mod_global_distrib_mapping, for_domain,
                              [<<"test_service.localhost">>])),

    component_helper:disconnect_component(Comp, Addr),

    ?assertEqual(error, rpc(europe_node1, mod_global_distrib_mapping, for_domain,
                            [<<"test_service.localhost">>])).

test_error_on_wrong_hosts(_Config) ->
    Opts = module_opts(#{local_host => <<"no_such_host">>}),
    ?assertException(error, {badrpc, {'EXIT', {#{what := check_host_failed,
                                                 domain := <<"no_such_host">>}, _}}},
                     dynamic_modules:ensure_modules(node_spec(europe_node1), <<"localhost">>,
                                                    [{mod_global_distrib, Opts}])).

refresh_nodes(Config) ->
    NodesKey = ?config(nodes_key, Config),
    NodeBin = ?config(node_to_expire, Config),
    redis_query(europe_node1, [<<"HSET">>, NodesKey, NodeBin, <<"0">>]),
    refresh_mappings(europe_node1, "by_refresh_nodes"),
    {ok, undefined} = redis_query(europe_node1, [<<"HGET">>, NodesKey, NodeBin]).

test_in_order_messages_on_multiple_connections(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              Seq = lists:seq(1, 100),
              lists:foreach(
                fun(I) ->
                        Stanza = escalus_stanza:chat_to(Eve, integer_to_binary(I)),
                        escalus_client:send(Alice, Stanza)
                end,
                Seq),
              lists:foreach(
                fun(I) ->
                        Stanza = escalus_client:wait_for_stanza(Eve, 5000),
                        escalus:assert(is_chat_message, [integer_to_binary(I)], Stanza)
                end,
                Seq)
      end).

test_in_order_messages_on_multiple_connections_with_bounce(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              %% Send 99 messages, some while server knows the mapping and some when it doesn't
              send_steps(Alice, Eve, 99, <<"reg1">>),
              %% Make sure that the last message is sent when the mapping is known
              set_mapping(europe_node1, Eve, <<"reg1">>),
              escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"100">>)),

              %% Check that all stanzas were received in order
              lists:foreach(
                fun(I) ->
                        Stanza = escalus_client:wait_for_stanza(Eve, 5000),
                        escalus:assert(is_chat_message, [integer_to_binary(I)], Stanza)
                end,
                lists:seq(1, 100))
      end).

test_messages_bounced_in_order(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              %% Make sure all messages land in bounce storage
              delete_mapping(europe_node1, Eve),

              wait_for_bounce_size(0),

              Seq = lists:seq(1, 99),
              lists:foreach(
                fun(I) ->
                        Stanza = escalus_stanza:chat_to(Eve, integer_to_binary(I)),
                        escalus_client:send(Alice, Stanza)
                end,
                Seq),

              wait_for_bounce_size(99),

              %% Restore the mapping so that bounce eventually succeeds
              ?assertEqual(undefined, get_mapping(europe_node1, Eve)),
              set_mapping(europe_node1, Eve, <<"reg1">>),

              %% Test used to work if the mapping is restored while Alice was still sending the 100 stanzas.
              %% This may actually be a race condition, and it should work like in the
              %% test_in_order_messages_on_multiple_connections_with_bounce testcase:
              %% Make sure that the last message is sent when the mapping is known
              escalus_client:send(Alice, escalus_stanza:chat_to(Eve, <<"100">>)),

              lists:foreach(
                fun(I) ->
                        Stanza = escalus_client:wait_for_stanza(Eve, 5000),
                        escalus:assert(is_chat_message, [integer_to_binary(I)], Stanza)
                end,
                Seq)
      end).

test_update_senders_host(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {eve, 1}],
      fun(Alice, Eve) ->
              AliceJid = rpc(asia_node, jid, from_binary, [escalus_client:full_jid(Alice)]),
              {ok, <<"localhost.bis">>}
              = rpc(asia_node, mod_global_distrib_mapping, for_jid, [AliceJid]),
              ok = rpc(europe_node1, mod_global_distrib_mapping, delete_for_jid, [AliceJid]),
              wait_for_node(asia_node, AliceJid),

              %% TODO: Should prevent Redis refresher from executing for a moment,
              %%       as it may collide with this test.

              escalus:send(Alice, escalus_stanza:chat_to(Eve, <<"test_update_senders_host">>)),
              escalus:wait_for_stanza(Eve),

              {ok, <<"localhost.bis">>}
              = rpc(asia_node, mod_global_distrib_mapping, for_jid, [AliceJid])
      end).
wait_for_node(Node,Jid) ->
    wait_helper:wait_until(fun() -> rpc(Node, mod_global_distrib_mapping, for_jid, [Jid]) end,
                           error,
                           #{time_left => timer:seconds(10),
                             sleep_time => timer:seconds(1),
                             name => rpc}).

test_update_senders_host_by_ejd_service(Config) ->
    refresh_hosts([europe_node1, europe_node2, asia_node], "by_test_update_senders_host_by_ejd_service"),
    %% Connects to europe_node1
    ComponentConfig = [{server, <<"localhost">>}, {host, <<"localhost">>}, {password, <<"secret">>},
                       {port, component_port()}, {component, <<"test_service">>}],

    {Comp, Addr, _Name} = component_helper:connect_component(ComponentConfig),

    escalus:fresh_story(
      Config, [{eve, 1}],
      fun(Eve) ->
              %% Eve is connected to asia_node
              EveJid = rpc(asia_node, jid, from_binary, [escalus_client:full_jid(Eve)]),
              {ok, <<"reg1">>} = rpc(europe_node1, mod_global_distrib_mapping, for_jid, [EveJid]),
              {ok, <<"reg1">>} = rpc(europe_node2, mod_global_distrib_mapping, for_jid, [EveJid]),

              ok = rpc(asia_node, mod_global_distrib_mapping, delete_for_jid, [EveJid]),
              wait_for_node(europe_node1, EveJid),
              wait_for_node(europe_node2, EveJid),

              %% Component is connected to europe_node1
              %% but we force asia_node to connect to europe_node2 by hiding europe_node1
              %% and forcing rebalance (effectively disabling connections to europe_node1)
              %% to verify routing cache update on both nodes

              %% TODO: Should prevent Redis refresher from executing for a moment,
              %%       as it may collide with this test.

              hide_node(europe_node1, Config),
              {_, EuropeHost, _} = lists:keyfind(europe_node1, 1, get_hosts()),
              trigger_rebalance(asia_node, EuropeHost),

              escalus:send(Eve, escalus_stanza:chat_to(Addr, <<"hi">>)),
              escalus:wait_for_stanza(Comp),

              {ok, <<"reg1">>} = rpc(europe_node1, mod_global_distrib_mapping, for_jid, [EveJid]),
              {ok, <<"reg1">>} = rpc(europe_node2, mod_global_distrib_mapping, for_jid, [EveJid])
      end).

%% -------------------------------- Rebalancing --------------------------------

enable_new_endpoint_on_refresh(Config) ->
    get_connection(europe_node1, <<"reg1">>),

    {Enabled1, _Disabled1, Pools1} = get_outgoing_connections(europe_node1, <<"reg1">>),

    ExtraPort = get_port(reg, gd_extra_endpoint_port),
    NewEndpoint = resolved_endpoint(ExtraPort),
    enable_extra_endpoint(asia_node, europe_node1, ExtraPort, Config),

    {Enabled2, _Disabled2, Pools2} = get_outgoing_connections(europe_node1, <<"reg1">>),

    %% One new pool and one new endpoint
    [NewEndpoint] = Pools2 -- Pools1,
    [] = Pools1 -- Pools2,
    [NewEndpoint] = Enabled2 -- Enabled1,
    [] = Enabled1 -- Enabled2.

disable_endpoint_on_refresh(Config) ->
    ExtraPort = get_port(reg, gd_extra_endpoint_port),
    NewEndpoint = resolved_endpoint(ExtraPort),
    enable_extra_endpoint(asia_node, europe_node1, ExtraPort, Config),

    get_connection(europe_node1, <<"reg1">>),

    {Enabled1, Disabled1, Pools1} = get_outgoing_connections(europe_node1, <<"reg1">>),
    [_, _] = Enabled1,
    [] = Disabled1,

    hide_extra_endpoint(asia_node),
    trigger_rebalance(europe_node1, <<"reg1">>),

    {Enabled2, Disabled2, Pools2} = get_outgoing_connections(europe_node1, <<"reg1">>),

    %% 2 pools open even after disable
    [] = Pools1 -- Pools2,
    [] = Pools2 -- Pools1,
    %% NewEndpoint is no longer enabled
    [] = Enabled2 -- Enabled1,
    [NewEndpoint] = Enabled1 -- Enabled2,
    %% NewEndpoint is now disabled
    [] = Disabled1,
    [NewEndpoint] = Disabled2.

wait_for_connection(_Config) ->
    set_endpoints(asia_node, []),
    %% Because of hosts refresher, a pool of connections to asia_node
    %% may already be present here
    wait_helper:wait_until(
      fun () ->
              try trigger_rebalance(europe_node1, <<"reg1">>), true
              catch _:_ -> false end
      end,
      true,
      #{name => rebalance, time_left => timer:seconds(5)}),

    spawn_connection_getter(europe_node1),

    receive
        Unexpected1 -> error({unexpected, Unexpected1})
    after
        2000 -> ok
    end,

    refresh_mappings(asia_node, "by_wait_for_connection"),
    trigger_rebalance(europe_node1, <<"reg1">>),

    receive
        Conn when is_pid(Conn) -> ok;
        Unexpected2 -> error({unexpected, Unexpected2})
    after
        5000 -> error(timeout)
    end.

closed_connection_is_removed_from_disabled(_Config) ->
    get_connection(europe_node1, <<"reg1">>),
    set_endpoints(asia_node, []),
    trigger_rebalance(europe_node1, <<"reg1">>),

    {[], [_], [_]} = get_outgoing_connections(europe_node1, <<"reg1">>),

    % Will drop connections and prevent them from reconnecting
    restart_receiver(asia_node, [get_port(reg, gd_supplementary_endpoint_port)]),

    wait_helper:wait_until(fun() -> get_outgoing_connections(europe_node1, <<"reg1">>) end,
                           {[], [], []},
                           #{name => get_outgoing_connections}).


%%--------------------------------------------------------------------
%% Test helpers
%%--------------------------------------------------------------------

get_port(Host, Param) ->
    case ct:get_config({hosts, Host, Param}) of
        Port when is_integer(Port) ->
            Port;
        Other ->
            ct:fail({get_port_failed, Host, Param, Other})
    end.

get_hosts() ->
    [
     {europe_node1, <<"localhost.bis">>, get_port(mim, gd_endpoint_port)},
     {europe_node2, <<"localhost.bis">>, get_port(mim2, gd_endpoint_port)},
     {asia_node, <<"reg1">>, get_port(reg, gd_endpoint_port)}
    ].

listen_endpoint(NodeName) ->
    endpoint(listen_port(NodeName)).

listen_port(NodeName) ->
    {_, _, Port} = lists:keyfind(NodeName, 1, get_hosts()),
    Port.

resolved_endpoint(Port) when is_integer(Port) ->
    {{127, 0, 0, 1}, Port}.

endpoint(Port) when is_integer(Port) ->
    {"127.0.0.1", Port}.

%% For dynamic_modules
node_spec(NodeName) ->
    #{node => ct:get_config(NodeName), timeout => timer:seconds(30)}.

rpc(NodeName, M, F, A) ->
    Node = ct:get_config(NodeName),
    mongoose_helper:successful_rpc(#{node => Node}, M, F, A, timer:seconds(30)).

hide_node(NodeName, Config) ->
    NodesKey = ?config(nodes_key, Config),
    NodeBin = atom_to_binary(ct:get_config(NodeName), latin1),
    {ok, <<"1">>} = redis_query(europe_node1, [<<"HDEL">>, NodesKey, NodeBin]).

connect_from_spec(UserSpec, Config) ->
    {ok, User} = escalus_client:start(Config, UserSpec, <<"res1">>),
    escalus_story:send_initial_presence(User),
    escalus:assert(is_presence, escalus_client:wait_for_stanza(User)),
    User.

chat_with_seqnum(To, Text) ->
    escalus_stanza:set_id(escalus_stanza:chat_to(To, Text),
                          integer_to_binary(erlang:monotonic_time())).

order_by_seqnum(Stanzas) ->
    lists:sort(fun(A, B) -> exml_query:attr(B, <<"id">>) < exml_query:attr(A, <<"id">>) end,
               Stanzas).

has_exactly_one_service(Service, #xmlel{children = [#xmlel{children = Services}]}) ->
    Pred = fun(Item) ->
                   exml_query:attr(Item, <<"jid">>) =:= Service
           end,
    case lists:filter(Pred, Services) of
        [_] -> true;
        _ -> false
    end.

send_steps(From, To, Max, ToHost) ->
    next_send_step(From, To, 1, Max, Max div 10, true, ToHost).

next_send_step(_From, _To, I, Max, _ToReset, _KnowsMapping, _ToHost) when I > Max -> ok;
next_send_step(From, To, I, Max, 0, KnowsMapping, ToHost) ->
    ct:log("Reset: I: ~B", [I]),
    case KnowsMapping of
        true -> delete_mapping(europe_node1, To);
        false -> set_mapping(europe_node1, To, ToHost)
    end,
    next_send_step(From, To, I, Max, Max div 10, not KnowsMapping, ToHost);
next_send_step(From, To, I, Max, ToReset, KnowsMapping, ToHost) ->
    ct:log("I: ~B ~B ~B", [I, Max, ToReset]),
    Stanza = escalus_stanza:chat_to(To, integer_to_binary(I)),
    escalus_client:send(From, Stanza),
    next_send_step(From, To, I + 1, Max, ToReset - 1, KnowsMapping, ToHost).

get_mapping(Node, Client) ->
    {FullJid, _BareJid} = jids(Client),
    {ok, What} = redis_query(Node, [<<"GET">>, FullJid]),
    What.

%% Warning! May not work properly with alice or any other user whose
%% stringprepped JID is different than original one
delete_mapping(Node, Client) ->
    {FullJid, BareJid} = jids(Client),
    redis_query(Node, [<<"DEL">>, FullJid, BareJid]),
    Jid = rpc(Node, jid, from_binary, [FullJid]),
    rpc(Node, mod_global_distrib_mapping, clear_cache, [Jid]).

set_mapping(Node, Client, Mapping) ->
    {FullJid, BareJid} = jids(Client),
    redis_query(Node, [<<"MSET">>, FullJid, Mapping, BareJid, Mapping]),
    Jid = rpc(Node, jid, from_binary, [FullJid]),
    rpc(Node, mod_global_distrib_mapping, clear_cache, [Jid]).

jids(Client) ->
    FullJid = escalus_client:full_jid(Client),
    BareJid = escalus_client:short_jid(Client),
    {FullJid, BareJid}.

redis_query(Node, Query) ->
    {ok, RedisWorker} = rpc(Node, mongoose_wpool, get_worker, [redis, global, global_distrib]),
    rpc(Node, eredis, q, [RedisWorker, Query]).

%% A fake address we don't try to connect to.
%% Used in test_advertised_endpoints_override_endpoints testcase.
advertised_endpoints() ->
    [
     {fake_domain(), get_port(reg, gd_endpoint_port)}
    ].

fake_domain() ->
    "somefakedomain.com".

iptuples_to_string([]) ->
    [];
iptuples_to_string([{Addr, Port} | Endps]) when is_tuple(Addr) ->
    [{inet_parse:ntoa(Addr), Port} | iptuples_to_string(Endps)];
iptuples_to_string([E | Endps]) ->
    [E | iptuples_to_string(Endps)].

endpoint_opts(NodeName, ReceiverPort, Config) ->
    Endpoints = [endpoint(ReceiverPort)],
    AdvertisedEndpoints =
        proplists:get_value(NodeName, ?config(add_advertised_endpoints, Config), Endpoints),
    #{endpoints => Endpoints,
      resolved_endpoints => [resolved_endpoint(ReceiverPort)],
      advertised_endpoints => AdvertisedEndpoints}.

mock_inet_on_each_node() ->
    Nodes = lists:map(fun({NodeName, _, _}) -> ct:get_config(NodeName) end, get_hosts()),
    Results = lists:map(fun(Node) -> rpc:block_call(Node, ?MODULE, mock_inet, []) end, Nodes),
    true = lists:all(fun(Result) -> Result =:= ok end, Results).

execute_on_each_node(M, F, A) ->
    lists:map(fun({NodeName, _, _}) -> rpc(NodeName, M, F, A) end, get_hosts()).

mock_inet() ->
    %% We can only mock MongooseIM modules on mim1.
    %% Otherwise meck will freeze calling cover_server process.
    meck:new(inet, [non_strict, passthrough, unstick]),
    meck:expect(inet, getaddrs, fun(_, inet) -> {ok, [{127, 0, 0, 1}]};
                                   (_, inet6) -> {error, "No ipv6 address"} end).

unmock_inet(_Pids) ->
    execute_on_each_node(meck, unload, [inet]).

out_connection_sups(Node) ->
    Children = rpc(Node, supervisor, which_children, [mod_global_distrib_outgoing_conns_sup]),
    lists:filter(fun({Sup, _, _, _}) -> Sup =/= mod_global_distrib_hosts_refresher end, Children).

trees_for_connections_present() ->
    AsiaChildren = out_connection_sups(asia_node),
    Europe1Children = out_connection_sups(europe_node1),
    Europe2Children = out_connection_sups(europe_node2),
    lists:all(fun(Host) -> length(Host) > 0 end, [AsiaChildren, Europe1Children, Europe2Children]).

tree_for_sup_present(Node, ExpectedSup) ->
    Children = out_connection_sups(Node),
    lists:keyfind(ExpectedSup, 1, Children) =/= false.


%% ------------------------------- rebalancing helpers -----------------------------------

spawn_connection_getter(SenderNode) ->
    TestPid = self(),
    spawn(fun() ->
                  Conn = get_connection(SenderNode, <<"reg1">>),
                  TestPid ! Conn
          end).

enable_extra_endpoint(ListenNode, SenderNode, Port, _Config) ->
    restart_receiver(ListenNode, [Port, listen_port(ListenNode)]),
    set_endpoints(ListenNode, [Port, listen_port(ListenNode)]),
    trigger_rebalance(SenderNode, <<"reg1">>).

get_connection(SenderNode, ToDomain) ->
    rpc(SenderNode, mod_global_distrib_outgoing_conns_sup, get_connection, [ToDomain]).

hide_extra_endpoint(ListenNode) ->
    set_endpoints(ListenNode, [listen_port(ListenNode)]).

set_endpoints(ListenNode, Ports) ->
    Endpoints = [endpoint(Port) || Port <- Ports],
    {ok, _} = rpc(ListenNode, mod_global_distrib_mapping_redis, set_endpoints, [Endpoints]).

get_outgoing_connections(NodeName, DestinationDomain) ->
    Supervisor = rpc(NodeName, mod_global_distrib_utils, server_to_sup_name, [DestinationDomain]),
    Manager = rpc(NodeName, mod_global_distrib_utils, server_to_mgr_name, [DestinationDomain]),
    Enabled = rpc(NodeName, mod_global_distrib_server_mgr,
                  get_enabled_endpoints, [DestinationDomain]),
    Disabled = rpc(NodeName, mod_global_distrib_server_mgr,
                   get_disabled_endpoints, [DestinationDomain]),
    PoolsChildren = rpc(NodeName, supervisor, which_children, [Supervisor]),
    Pools = [ Id || {Id, _Child, _Type, _Modules} <- PoolsChildren, Id /= Manager ],
    {Enabled, Disabled, Pools}.

restart_receiver(NodeName) ->
    restart_receiver(NodeName, [listen_port(NodeName)]).

restart_receiver(NodeName, NewPorts) ->
    OldOpts = #{connections := OldConnOpts} = rpc(NodeName, gen_mod, get_module_opts,
                                                  [<<"localhost">>, mod_global_distrib_receiver]),
    NewConnOpts = OldConnOpts#{endpoints := [endpoint(Port) || Port <- NewPorts],
                               resolved_endpoints := [resolved_endpoint(Port) || Port <- NewPorts]},
    NewOpts = OldOpts#{connections := NewConnOpts},
    Node = node_spec(NodeName),
    dynamic_modules:restart(Node, <<"localhost">>, mod_global_distrib_receiver, NewOpts).

trigger_rebalance(NodeName, DestinationDomain) when is_binary(DestinationDomain) ->
    %% To ensure that the manager exists,
    %% otherwise we can get noproc error in the force_refresh call
    ok = rpc(NodeName, mod_global_distrib_outgoing_conns_sup,
             ensure_server_started, [DestinationDomain]),
    rpc(NodeName, mod_global_distrib_server_mgr, force_refresh, [DestinationDomain]),
    StateInfo = rpc(NodeName, mod_global_distrib_server_mgr, get_state_info, [DestinationDomain]),
    ct:log("mgr_state_info_after_rebalance nodename=~p state_info=~p", [NodeName, StateInfo]),
    timer:sleep(1000).

%% -----------------------------------------------------------------------
%% Escalus-related helpers

%% Receive messages with Bodies in any order, skipping presences from stream resumption
user_receives(User, Bodies) ->
    Opts = #{pred => fun(Stanza) -> not escalus_pred:is_presence(Stanza) end},
    Checks = [fun(Stanza) -> escalus_pred:is_chat_message(Body, Stanza) end || Body <- Bodies],
    escalus:assert_many(Checks, [escalus_connection:receive_stanza(User, Opts) || _ <- Bodies]).

%% -----------------------------------------------------------------------
%% Refreshing helpers

%% Reason is a string
%% NodeName is asia_node, europe_node2, ... in a format used by this suite.
refresh_mappings(NodeName, Reason) when is_list(Reason) ->
    rpc(NodeName, mod_global_distrib_mapping_redis, refresh, [Reason]).

refresh_hosts(NodeNames, Reason) ->
   [refresh_mappings(NodeName, Reason) || NodeName <- NodeNames].


%% -----------------------------------------------------------------------
%% Other helpers

connect_steps_with_sm() ->
    [start_stream, stream_features, maybe_use_ssl,
     authenticate, bind, session, stream_resumption].

bare_client(Client) ->
    Client#client{jid = escalus_utils:get_short_jid(Client)}.

component_port() ->
    ct:get_config({hosts, mim, component_port}).

wait_for_bounce_size(ExpectedSize) ->
    F = fun(#{size := Size}) -> Size =:= ExpectedSize end,
    instrument_helper:wait_and_assert_new(mod_global_distrib_bounce_queue, #{}, F).

%% -----------------------------------------------------------------------
%% Waiting helpers

wait_for_domain(Node, Domain) ->
    F = fun() ->
                Domains = rpc:call(Node, mod_global_distrib_mapping, all_domains, []),
                lists:member(Domain, Domains)
        end,
    wait_helper:wait_until(F, true, #{name => {wait_for_domain, Node, Domain}}).


%% -----------------------------------------------------------------------
%% Ensure, that endpoints are up

wait_for_listeners_to_appear() ->
    [wait_for_can_connect_to_port(Port) || Port <- receiver_ports(get_hosts())].

receiver_ports(Hosts) ->
    lists:map(fun({_NodeName, _LocalHost, ReceiverPort}) -> ReceiverPort end, Hosts).

wait_for_can_connect_to_port(Port) ->
    Opts = #{time_left => timer:seconds(30), sleep_time => 1000, name => {can_connect_to_port, Port}},
    wait_helper:wait_until(fun() -> can_connect_to_port(Port) end, true, Opts).

can_connect_to_port(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, []) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            true;
        Other ->
            ct:pal("can_connect_to_port port=~p result=~p", [Port, Other]),
            false
    end.

%% Prints information about the active sessions
print_sessions_debug_info(NodeName) ->
    Node = rpc(NodeName, erlang, node, []),
    Nodes = rpc(NodeName, erlang, nodes, []),
    ct:log("name=~p, erlang_node=~p, other_nodes=~p", [NodeName, Node, Nodes]),

    Children = rpc(NodeName, supervisor, which_children, [mongoose_c2s_sup]),
    ct:log("C2S processes under a supervisour ~p", [Children]),

    Sessions = rpc(NodeName, ejabberd_sm, get_full_session_list, []),
    ct:log("C2S processes in the session manager ~p", [Sessions]),

    Sids = [element(2, Session) || Session <- Sessions],
    Pids = [Pid || {_, Pid} <- Sids],
    PidNodes = [{Pid, node(Pid)} || Pid <- Pids],
    ct:log("Pids on nodes ~p", [PidNodes]),

    Info = [{Pid, rpc:call(N, erlang, process_info, [Pid])} || {Pid, N} <- PidNodes],
    ct:log("Processes info ~p", [Info]),
    ok.

%% -----------------------------------------------------------------------
%% Custom log levels for GD modules during the tests

%% Set it to true, if you need to debug GD on CI
detailed_logging() ->
    false.

enable_logging() ->
    detailed_logging() andalso
        mim_loglevel:enable_logging(test_hosts(), custom_loglevels()).

disable_logging() ->
    detailed_logging() andalso
        mim_loglevel:disable_logging(test_hosts(), custom_loglevels()).

custom_loglevels() ->
    %% for "s2s connection to muc.localhost not found" debugging
    [{ejabberd_s2s, debug},
    %% for debugging event=refreshing_own_data_done
     {mod_global_distrib_mapping_redis, info},
    %% to know if connection is already started or would be started
    %% event=outgoing_conn_start_progress
     {mod_global_distrib_outgoing_conns_sup, info},
    %% to debug bound connection issues
     {mod_global_distrib, debug},
    %% to know all new connections pids
     {mod_global_distrib_connection, debug},
    %% to check if gc or refresh is triggered
     {mod_global_distrib_server_mgr, info},
    %% To debug incoming connections
%    {mod_global_distrib_receiver, info},
    %% to debug global session set/delete
     {mod_global_distrib_mapping, debug},
    %% To log make_error_reply calls
     {jlib, debug},
    %% to log sm_route
     {ejabberd_sm, debug}
    ].

test_hosts() -> [mim, mim2, reg].
