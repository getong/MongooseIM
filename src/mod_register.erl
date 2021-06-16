%%%----------------------------------------------------------------------
%%% File    : mod_register.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Inband registration support
%%% Created :  8 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
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
%%%----------------------------------------------------------------------

-module(mod_register).
-author('alexey@process-one.net').
-xep([{xep, 77}, {version, "2.4"}]).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

-export([start/2,
         stop/1,
         config_spec/0,
         c2s_stream_features/3,
         unauthenticated_iq_register/4,
         try_register/5,
         process_iq/4,
         process_ip_access/1,
         process_welcome_message/1]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include("mongoose_config_spec.hrl").

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_REGISTER,
                                  ?MODULE, process_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_REGISTER,
                                  ?MODULE, process_iq, IQDisc),
    ejabberd_hooks:add(c2s_stream_features, Host,
                       ?MODULE, c2s_stream_features, 50),
    ejabberd_hooks:add(c2s_unauthenticated_iq, Host,
                       ?MODULE, unauthenticated_iq_register, 50),
    mnesia:create_table(mod_register_ip,
                        [{ram_copies, [node()]},
                         {local_content, true},
                         {attributes, [key, value]}]),
    mnesia:add_table_copy(mod_register_ip, node(), ram_copies),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_stream_features, Host,
                          ?MODULE, c2s_stream_features, 50),
    ejabberd_hooks:delete(c2s_unauthenticated_iq, Host,
                          ?MODULE, unauthenticated_iq_register, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_REGISTER),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_REGISTER).

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"iqdisc">> => mongoose_config_spec:iqdisc(),
                 <<"access">> => #option{type = atom,
                                         validate = access_rule},
                 <<"welcome_message">> => welcome_message_spec(),
                 <<"registration_watchers">> => #list{items = #option{type = binary,
                                                                      validate = jid}},
                 <<"password_strength">> => #option{type = integer,
                                                    validate = non_negative},
                 <<"ip_access">> => #list{items = ip_access_spec()}
                }
      }.

welcome_message_spec() ->
    #section{
        items = #{<<"body">> => #option{type = string},
                  <<"subject">> => #option{type = string}},
        process = fun ?MODULE:process_welcome_message/1
    }.

ip_access_spec() ->
    #section{
        items = #{<<"address">> => #option{type = string,
                                           validate = ip_mask},
                  <<"policy">> => #option{type = atom,
                                          validate = {enum, [allow, deny]}}
                },
        required = all,
        process = fun ?MODULE:process_ip_access/1
    }.

process_ip_access(KVs) ->
    {[[{address, Address}], [{policy, Policy}]], []} = proplists:split(KVs, [address, policy]),
    {Policy, Address}.

process_welcome_message(KVs) ->
    Body = proplists:get_value(body, KVs, ""),
    Subject = proplists:get_value(subject, KVs, ""),
    {Subject, Body}.

-spec c2s_stream_features([exml:element()], mongooseim:host_type(), jid:lserver()) ->
          [exml:element()].
c2s_stream_features(Acc, _HostType, _LServer) ->
    [#xmlel{name = <<"register">>,
            attrs = [{<<"xmlns">>, ?NS_FEATURE_IQREGISTER}]} | Acc].

unauthenticated_iq_register(_Acc,
                            Server, #iq{xmlns = ?NS_REGISTER} = IQ, IP) ->
    Address = case IP of
                  {A, _Port} -> A;
                  _ -> undefined
              end,
    ResIQ = process_unauthenticated_iq(no_JID,
                                       %% For the above: the client is
                                       %% not registered (no JID), at
                                       %% least not yet, so they can
                                       %% not be authenticated either.
                                       make_host_only_jid(Server),
                                       IQ,
                                       Address),
    set_sender(jlib:iq_to_xml(ResIQ), make_host_only_jid(Server));
unauthenticated_iq_register(Acc, _Server, _IQ, _IP) ->
    Acc.

%% Clients must register before being able to authenticate.
process_unauthenticated_iq(From, To, #iq{type = set} = IQ, IPAddr) ->
    process_iq_set(From, To, IQ, IPAddr);
process_unauthenticated_iq(From, To, #iq{type = get} = IQ, IPAddr) ->
    process_iq_get(From, To, IQ, IPAddr).

process_iq(From, To, Acc, #iq{type = set} = IQ) ->
    Res = process_iq_set(From, To, IQ, jid:to_lower(From)),
    {Acc, Res};
process_iq(From, To, Acc, #iq{type = get} = IQ) ->
    Res = process_iq_get(From, To, IQ, jid:to_lower(From)),
    {Acc, Res}.

process_iq_set(From, To, #iq{sub_el = Child} = IQ, Source) ->
    true = is_query_element(Child),
    handle_set(IQ, From, To, Source).

handle_set(IQ, ClientJID, ServerJID, Source) ->
    #iq{sub_el = Query} = IQ,
    case which_child_elements(Query) of
        bad_request ->
            error_response(IQ, mongoose_xmpp_errors:bad_request());
        only_remove_child ->
            attempt_cancelation(ClientJID, ServerJID, IQ);
        various_elements_present ->
            case has_username_and_password_children(Query) of
                true ->
                    Credentials = get_username_and_password_values(Query),
                    register_or_change_password(Credentials, ClientJID, ServerJID, IQ, Source);
                false ->
                    error_response(IQ, mongoose_xmpp_errors:bad_request())
            end
    end.

which_child_elements(#xmlel{children = C} = Q) when length(C) =:= 1 ->
        case Q#xmlel.children of
            [#xmlel{name = <<"remove">>}] ->
                only_remove_child;
            [_] ->
                bad_request
        end;
which_child_elements(#xmlel{children = C} = Q) when length(C) > 1 ->
    case exml_query:subelement(Q, <<"remove">>) of
        #xmlel{name = <<"remove">>} ->
            bad_request;
        undefined ->
            various_elements_present
    end;
which_child_elements(#xmlel{children = []}) ->
    bad_request.

has_username_and_password_children(Q) ->
    (undefined =/= exml_query:path(Q, [{element, <<"username">>}]))
     and
    (undefined =/= exml_query:path(Q, [{element, <<"password">>}])).

get_username_and_password_values(Q) ->
    {exml_query:path(Q, [{element, <<"username">>}, cdata]),
     exml_query:path(Q, [{element, <<"password">>}, cdata])}.

register_or_change_password(Credentials, ClientJID, #jid{lserver = ServerDomain}, IQ, IPAddr) ->
    {Username, Password} = Credentials,
    case inband_registration_and_cancelation_allowed(ServerDomain, ClientJID) of
        true ->
            #iq{sub_el = Children, lang = Lang} = IQ,
            try_register_or_set_password(Username, ServerDomain, Password,
                                         ClientJID, IQ, Children, IPAddr, Lang);
        false ->
            %% This is not described in XEP 0077.
            error_response(IQ, mongoose_xmpp_errors:forbidden())
    end.

attempt_cancelation(#jid{} = ClientJID, #jid{lserver = ServerDomain}, #iq{} = IQ) ->
    case inband_registration_and_cancelation_allowed(ServerDomain, ClientJID) of
        true ->
            %% The response must be sent *before* the
            %% XML stream is closed (the call to
            %% `ejabberd_auth:remove_user/1' does
            %% this): as it is, when canceling a
            %% registration, there is no way to deal
            %% with failure.
            ResIQ = IQ#iq{type = result, sub_el = []},
            ejabberd_router:route(
              jid:make_noprep(<<>>, <<>>, <<>>),
              ClientJID,
              jlib:iq_to_xml(ResIQ)),
            ejabberd_auth:remove_user(ClientJID),
            ignore;
        false ->
            error_response(IQ, mongoose_xmpp_errors:not_allowed())
    end.

inband_registration_and_cancelation_allowed(_, no_JID) ->
    true;
inband_registration_and_cancelation_allowed(Server, JID) ->
    Rule = gen_mod:get_module_opt(Server, ?MODULE, access, none),
    allow =:= acl:match_rule(Server, Rule, JID).

process_iq_get(From, _To, #iq{lang = Lang, sub_el = Child} = IQ, _Source) ->
    true = is_query_element(Child),
    {_IsRegistered, UsernameSubels, QuerySubels} =
        case From of
            JID = #jid{user = User} ->
                case ejabberd_auth:does_user_exist(JID) of
                    true ->
                        {true, [#xmlcdata{content = User}],
                         [#xmlel{name = <<"registered">>}]};
                    false ->
                        {false, [#xmlcdata{content = User}], []}
                end;
            _ ->
                {false, [], []}
        end,
    TranslatedMsg = translate:translate(
                      Lang, <<"Choose a username and password to register with this server">>),
    IQ#iq{type = result,
          sub_el = [#xmlel{name = <<"query">>,
                           attrs = [{<<"xmlns">>, <<"jabber:iq:register">>}],
                           children = [#xmlel{name = <<"instructions">>,
                                              children = [#xmlcdata{content = TranslatedMsg}]},
                                       #xmlel{name = <<"username">>,
                                              children = UsernameSubels},
                                       #xmlel{name = <<"password">>}
                                       | QuerySubels]}]}.

try_register_or_set_password(User, Server, Password, #jid{user = User, lserver = Server} = UserJID,
                             IQ, SubEl, _Source, Lang) ->
    try_set_password(UserJID, Password, IQ, SubEl, Lang);
try_register_or_set_password(User, Server, Password, _From, IQ, SubEl, Source, Lang) ->
    case check_timeout(Source) of
        true ->
            case try_register(User, Server, Password, Source, Lang) of
                ok ->
                    IQ#iq{type = result, sub_el = [SubEl]};
                {error, Error} ->
                    error_response(IQ, [SubEl, Error])
            end;
        false ->
            ErrText = <<"Users are not allowed to register accounts so quickly">>,
            error_response(IQ, mongoose_xmpp_errors:resource_constraint(Lang, ErrText))
    end.

%% @doc Try to change password and return IQ response
try_set_password(#jid{lserver = LServer} = UserJID, Password, IQ, SubEl, Lang) ->
    case is_strong_password(LServer, Password) of
        true ->
            case ejabberd_auth:set_password(UserJID, Password) of
                ok ->
                    IQ#iq{type = result, sub_el = [SubEl]};
                {error, empty_password} ->
                    error_response(IQ, [SubEl, mongoose_xmpp_errors:bad_request()]);
                {error, not_allowed} ->
                    error_response(IQ, [SubEl, mongoose_xmpp_errors:not_allowed()]);
                {error, invalid_jid} ->
                    error_response(IQ, [SubEl, mongoose_xmpp_errors:item_not_found()])
            end;
        false ->
            ErrText = <<"The password is too weak">>,
            error_response(IQ, [SubEl, mongoose_xmpp_errors:not_acceptable(Lang, ErrText)])
    end.

try_register(User, Server, Password, SourceRaw, Lang) ->
    case jid:is_nodename(User) of
        false ->
            {error, mongoose_xmpp_errors:bad_request()};
        _ ->
            JID = jid:make(User, Server, <<>>),
            Access = gen_mod:get_module_opt(Server, ?MODULE, access, all),
            IPAccess = get_ip_access(Server),
            case {acl:match_rule(Server, Access, JID),
                  check_ip_access(SourceRaw, IPAccess)} of
                {deny, _} ->
                    {error, mongoose_xmpp_errors:forbidden()};
                {_, deny} ->
                    {error, mongoose_xmpp_errors:forbidden()};
                {allow, allow} ->
                    verify_password_and_register(JID, Password, SourceRaw, Lang)
            end
    end.

verify_password_and_register(#jid{lserver = LServer} = JID, Password, SourceRaw, Lang) ->
    case is_strong_password(LServer, Password) of
        true ->
            case ejabberd_auth:try_register(JID, Password) of
                {error, exists} ->
                    {error, mongoose_xmpp_errors:conflict()};
                {error, invalid_jid} ->
                    {error, mongoose_xmpp_errors:jid_malformed()};
                {error, not_allowed} ->
                    {error, mongoose_xmpp_errors:not_allowed()};
                {error, null_password} ->
                    {error, mongoose_xmpp_errors:not_acceptable()};
                _ ->
                    send_welcome_message(JID),
                    send_registration_notifications(JID, SourceRaw),
                    ok
            end;
        false ->
            ErrText = <<"The password is too weak">>,
            {error, mongoose_xmpp_errors:not_acceptable(Lang, ErrText)}
    end.

send_welcome_message(#jid{lserver = Host} = JID) ->
    case gen_mod:get_module_opt(Host, ?MODULE, welcome_message, {"", ""}) of
        {"", ""} ->
            ok;
        {Subj, Body} ->
            ejabberd_router:route(
              jid:make_noprep(<<>>, Host, <<>>),
              JID,
              #xmlel{name = <<"message">>, attrs = [{<<"type">>, <<"normal">>}],
                     children = [#xmlel{name = <<"subject">>,
                                        children = [#xmlcdata{content = Subj}]},
                                 #xmlel{name = <<"body">>,
                                        children = [#xmlcdata{content = Body}]}]});
        _ ->
            ok
    end.

send_registration_notifications(#jid{lserver = Host} = UJID, Source) ->
    case gen_mod:get_module_opt(Host, ?MODULE, registration_watchers, []) of
        [] -> ok;
        JIDs when is_list(JIDs) ->
            Body = lists:flatten(
                     io_lib:format(
                       "[~s] The account ~s was registered from IP address ~s "
                       "on node ~w using ~p.",
                       [get_time_string(), jid:to_binary(UJID),
                        ip_to_string(Source), node(), ?MODULE])),
            lists:foreach(fun(S) -> send_registration_notification(S, Host, Body) end, JIDs);
        _ ->
            ok
    end.

send_registration_notification(JIDBin, Host, Body) ->
    case jid:from_binary(JIDBin) of
        error -> ok;
        JID ->
            Message = #xmlel{name = <<"message">>,
                             attrs = [{<<"type">>, <<"chat">>}],
                             children = [#xmlel{name = <<"body">>,
                                                children = [#xmlcdata{content = Body}]}]},
            ejabberd_router:route(jid:make_noprep(<<>>, Host, <<>>), JID, Message)
    end.

check_timeout(undefined) ->
    true;
check_timeout(Source) ->
    Timeout = case ejabberd_config:get_local_option(registration_timeout) of
                  undefined -> 600;
                  TO -> TO
              end,
    case is_integer(Timeout) of
        true ->
            Priority = -(erlang:system_time(second)),
            CleanPriority = Priority + Timeout,
            F = fun() -> check_and_store_ip_entry(Source, Priority, CleanPriority) end,

            case mnesia:transaction(F) of
                {atomic, Res} ->
                    Res;
                {aborted, Reason} ->
                    ?LOG_ERROR(#{what => reg_check_timeout_failed,
                                 reg_source => Source, reason => Reason}),
                    true
            end;
        false ->
            true
    end.

check_and_store_ip_entry(Source, Priority, CleanPriority) ->
    Treap = case mnesia:read(mod_register_ip, treap, write) of
                [] ->
                    treap:empty();
                [{mod_register_ip, treap, T}] -> T
            end,
    Treap1 = clean_treap(Treap, CleanPriority),
    case treap:lookup(Source, Treap1) of
        error ->
            Treap2 = treap:insert(Source, Priority, [],
                                  Treap1),
            mnesia:write({mod_register_ip, treap, Treap2}),
            true;
        {ok, _, _} ->
            mnesia:write({mod_register_ip, treap, Treap1}),
            false
    end.

clean_treap(Treap, CleanPriority) ->
    case treap:is_empty(Treap) of
        true ->
            Treap;
        false ->
            {_Key, Priority, _Value} = treap:get_root(Treap),
            case Priority > CleanPriority of
                true -> clean_treap(treap:delete_root(Treap), CleanPriority);
                false -> Treap
            end
    end.

ip_to_string(Source) when is_tuple(Source) -> inet_parse:ntoa(Source);
ip_to_string(undefined) -> "undefined";
ip_to_string(_) -> "unknown".

get_time_string() -> write_time(erlang:localtime()).
%% Function copied from ejabberd_logger_h.erl and customized
write_time({{Y, Mo, D}, {H, Mi, S}}) ->
    io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
                  [Y, Mo, D, H, Mi, S]).

is_strong_password(LServer, Password) ->
    case gen_mod:get_module_opt(LServer, ?MODULE, password_strength, 0) of
        Entropy when is_number(Entropy), Entropy == 0 ->
            true;
        Entropy when is_number(Entropy), Entropy > 0 ->
            ejabberd_auth:entropy(Password) >= Entropy;
        Wrong ->
            ?LOG_WARNING(#{what => reg_wrong_password_strength,
                           host => LServer, value => Wrong}),
            true
    end.

%%%
%%% ip_access management
%%%

get_ip_access(Host) ->
    IPAccess = gen_mod:get_module_opt(Host, ?MODULE, ip_access, []),
    lists:flatmap(
      fun({Access, {IP, Mask}}) ->
              [{Access, IP, Mask}];
         ({Access, S}) ->
              case mongoose_lib:parse_ip_netmask(S) of
                  {ok, {IP, Mask}} ->
                      [{Access, IP, Mask}];
                  error ->
                      ?LOG_ERROR(#{what => reg_invalid_network_specification,
                                   specification => S}),
                      []
              end
      end, IPAccess).

check_ip_access(_Source, []) ->
    allow;
check_ip_access({User, Server, Resource}, IPAccess) ->
    case ejabberd_sm:get_session_ip(jid:make(User, Server, Resource)) of
        {IPAddress, _PortNumber} -> check_ip_access(IPAddress, IPAccess);
        _ -> true
    end;
check_ip_access({_, _, _, _} = IP,
                [{Access, {_, _, _, _} = Net, Mask} | IPAccess]) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot ((1 bsl (32 - Mask)) - 1),
    case IPInt band M =:= NetInt band M of
        true -> Access;
        false -> check_ip_access(IP, IPAccess)
    end;
check_ip_access({_, _, _, _, _, _, _, _} = IP,
                [{Access, {_, _, _, _, _, _, _, _} = Net, Mask} | IPAccess]) ->
    IPInt = ip_to_integer(IP),
    NetInt = ip_to_integer(Net),
    M = bnot ((1 bsl (128 - Mask)) - 1),
    case IPInt band M =:= NetInt band M of
        true -> Access;
        false -> check_ip_access(IP, IPAccess)
    end;
check_ip_access(IP, [_ | IPAccess]) ->
    check_ip_access(IP, IPAccess).

ip_to_integer({IP1, IP2, IP3, IP4}) ->
    <<X:32>> = <<IP1, IP2, IP3, IP4>>,
    X;
ip_to_integer({IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}) ->
    <<X:64>> = <<IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8>>,
    X.

make_host_only_jid(Name) when is_binary(Name) ->
    jid:make(<<>>, Name, <<>>).

set_sender(#xmlel{attrs = A} = Stanza, #jid{} = From) ->
    Stanza#xmlel{attrs = [{<<"from">>, jid:to_binary(From)}|A]}.

is_query_element(#xmlel{name = <<"query">>}) ->
    true;
is_query_element(_) ->
    false.

error_response(Request, Reasons) when is_list(Reasons) ->
    Request#iq{type = error, sub_el = Reasons};
error_response(Request, Reason) ->
    Request#iq{type = error, sub_el = Reason}.
