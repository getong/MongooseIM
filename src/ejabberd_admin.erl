%%%-------------------------------------------------------------------
%%% File    : ejabberd_admin.erl
%%% Author  : Mickael Remond <mremond@process-one.net>
%%% Purpose : Administrative functions and commands
%%% Created :  7 May 2006 by Mickael Remond <mremond@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
%%%
%%%-------------------------------------------------------------------

-module(ejabberd_admin).
-author('mickael.remond@process-one.net').

-export([start/0, stop/0,
         %% Server
         status/0,
         %% Accounts
         register/3, register/2, unregister/2,
         registered_users/1,
         import_users/1,
         %% Purge DB
         delete_expired_messages/1, delete_old_messages/2,
         remove_from_cluster/1]).

-ignore_xref([
    backup_mnesia/1, delete_expired_messages/1, delete_old_messages/2,
    dump_mnesia/1, dump_table/2,
    import_users/1, install_fallback_mnesia/1,
    load_mnesia/1, mnesia_change_nodename/4,
    register/2, register/3, registered_users/1, remove_from_cluster/1,
    restore_mnesia/1, status/0,
    stop/0, unregister/2]).

-include("mongoose.hrl").

start() ->
    ok.

stop() ->
    ok.

%%%
%%% Commands
%%%
-spec status() -> {ok, {boolean(), iolist()}}.
status() ->
    {ok, {Status, Message, _}} = mongoose_server_api:status(),
    {ok, {Status, Message}}.

%%%
%%% Server management
%%%
-spec remove_from_cluster(string()) -> {ok, string()} |
                                       {node_is_alive, string()} |
                                       {mnesia_error, string()} |
                                       {rpc_error, string()}.
remove_from_cluster(NodeString) ->
    Node = list_to_atom(NodeString),
    IsNodeAlive = mongoose_cluster:is_node_alive(Node),
    case IsNodeAlive of
        true ->
            remove_rpc_alive_node(Node);
        false ->
            remove_dead_node(Node)
    end.

remove_dead_node(DeadNode) ->
    try mongoose_cluster:remove_from_cluster(DeadNode) of
        ok ->
            String = io_lib:format("The dead node ~p has been removed from the cluster~n", [DeadNode]),
            {ok, String}
    catch
        error:{node_is_alive, DeadNode} ->
            String = io_lib:format("The node ~p is alive but shoud not be.~n", [DeadNode]),
            {node_is_alive, String};
        error:{del_table_copy_schema, R} ->
            String = io_lib:format("Cannot delete table schema~n. Reason: ~p", [R]),
            {mnesia_error, String}
    end.

remove_rpc_alive_node(AliveNode) ->
    case rpc:call(AliveNode, mongoose_cluster, leave, []) of
        {badrpc, Reason} ->
            String = io_lib:format("Cannot remove the node ~p~n. RPC Reason: ~p", [AliveNode, Reason]),
            {rpc_error, String};
        ok ->
            String = io_lib:format("The node ~p has been removed from the cluster~n", [AliveNode]),
            {ok, String};
        Unknown ->
            String = io_lib:format("Unknown error: ~p~n", [Unknown]),
            {rpc_error, String}
    end.


%%%
%%% Account management
%%%

-spec register(Host :: jid:server(),
               Password :: binary()) -> mongoose_account_api:register_result().
register(Host, Password) ->
    {Result, _} = mongoose_account_api:register_generated_user(Host, Password),
    Result.

-spec register(User :: jid:user(),
               Host :: jid:server(),
               Password :: binary()) -> mongoose_account_api:register_result().
register(User, Host, Password) ->
    mongoose_account_api:register_user(User, Host, Password).

-spec unregister(User :: jid:user(),
                 Host :: jid:server()) -> mongoose_account_api:unregister_result().
unregister(User, Host) ->
    mongoose_account_api:unregister_user(User, Host).


-spec registered_users(Host :: jid:server()) -> mongoose_account_api:list_user_result().
registered_users(Host) ->
    mongoose_account_api:list_users(Host).

-spec import_users(file:filename()) -> [{binary(), jid:user() | binary()}].
import_users(Filename) ->
    {ok, Result} = mongoose_import_users:run(Filename),
    maps:to_list(Result).

%%%
%%% Purge DB
%%%

-spec delete_expired_messages(binary()) -> {ok, iolist()} | {error, iolist()}.
delete_expired_messages(Domain) ->
    case mod_offline_api:delete_expired_messages(jid:nameprep(Domain)) of
        {ok, _} = Result -> Result;
        {_, Message} -> {error, Message}
    end.

-spec delete_old_messages(binary(), Days :: integer()) -> {ok, iolist()} | {error, iolist()}.
delete_old_messages(Domain, Days) ->
    case mod_offline_api:delete_old_messages(jid:nameprep(Domain), Days) of
        {ok, _} = Result -> Result;
        {_, Message} -> {error, Message}
    end.
