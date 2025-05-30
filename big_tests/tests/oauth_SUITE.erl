%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
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

-module(oauth_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml.hrl").

-import(distributed_helper, [mim/0,
                             require_rpc_nodes/1,
                             rpc/4]).

-import(domain_helper, [domain/0]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [
     {group, token_login},
     {group, token_revocation},
     {group, provision_token},
     {group, cleanup},
     {group, sasl_mechanisms}
    ].

groups() ->
    G = [
         {token_login, [sequence], token_login_tests()},
         {token_revocation, [sequence], token_revocation_tests()},
         {provision_token, [], [provision_token_login]},
         {cleanup, [], [token_removed_on_user_removal]},
         {sasl_mechanisms, [], [check_for_oauth_with_mod_auth_token_not_loaded,
                                check_for_oauth_with_mod_auth_token_loaded]}
        ],
    ct_helper:repeat_all_until_all_ok(G).

token_login_tests() ->
    [
     disco_test,
     request_tokens_test,
     login_access_token_test,
     login_refresh_token_test,
     login_with_other_users_token,
     login_with_malformed_token
    ].

token_revocation_tests() ->
    [
     login_with_revoked_token_test,
     token_revocation_test
    ].

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config0) ->
    case mongoose_helper:is_rdbms_enabled(domain_helper:host_type()) of
        true ->
            HostType = domain_helper:host_type(),
            Config = dynamic_modules:save_modules(HostType, Config0),
            dynamic_modules:ensure_modules(HostType, required_modules()),
            escalus:init_per_suite(Config);
        false ->
            {skip, "RDBMS not available"}
    end.

end_per_suite(Config) ->
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(GroupName, Config) ->
    AuthOpts = mongoose_helper:auth_opts_with_password_format(password_format(GroupName)),
    HostType = domain_helper:host_type(),
    Config1 = mongoose_helper:backup_and_set_config_option(Config, {auth, HostType}, AuthOpts),
    Config2 = escalus:create_users(Config1, escalus:get_users([bob, alice])),
    assert_password_format(GroupName, Config2).

password_format(login_scram) -> scram;
password_format(_) -> plain.

end_per_group(cleanup, Config) ->
    mongoose_helper:restore_config(Config),
    escalus:delete_users(Config, escalus:get_users([alice]));
end_per_group(_GroupName, Config) ->
    mongoose_helper:restore_config(Config),
    escalus:delete_users(Config, escalus:get_users([bob, alice])).

init_per_testcase(check_for_oauth_with_mod_auth_token_not_loaded, Config) ->
    HostType = domain_helper:host_type(),
    dynamic_modules:stop(HostType, mod_auth_token),
    init_per_testcase(generic, Config);
init_per_testcase(CaseName, Config) ->
    clean_token_db(),
    escalus:init_per_testcase(CaseName, Config).


end_per_testcase(check_for_oauth_with_mod_auth_token_not_loaded, Config) ->
    HostType = domain_helper:host_type(),
    dynamic_modules:start(HostType, mod_auth_token, auth_token_opts()),
    end_per_testcase(generic, Config);
end_per_testcase(CaseName, Config) ->
    clean_token_db(),
    escalus:end_per_testcase(CaseName, Config).


%%
%% Tests
%%

disco_test(Config) ->
    escalus:story(
      Config, [{alice, 1}],
      fun(Alice) ->
              escalus_client:send(Alice, escalus_stanza:disco_info(domain())),
              Response = escalus_client:wait_for_stanza(Alice),
              escalus:assert(has_feature, [?NS_ESL_TOKEN_AUTH], Response)
      end).

request_tokens_test(Config) ->
    request_tokens_once_logged_in_impl(Config, bob).

login_with_revoked_token_test(Config) ->
    %% given
    RevokedToken = get_revoked_token(Config, bob),
    token_login_failure(Config, bob, RevokedToken).

token_login_failure(Config, User, Token) ->
    %% when
    Result = login_with_token(Config, User, Token),
    % then
    {{auth_failed, _}, _} = Result.

get_revoked_token(Config, UserName) ->
    BJID = escalus_users:get_jid(Config, UserName),
    JID = jid:from_binary(BJID),
    HostType = domain_helper:host_type(),
    Token = rpc(mim(), mod_auth_token, token, [HostType, JID, refresh]),
    ValidSeqNo = rpc(mim(), mod_auth_token_rdbms, get_valid_sequence_number, [HostType, JID]),
    RevokedToken0 = record_set(Token, [{5, invalid_sequence_no(ValidSeqNo)},
                                       {7, undefined},
                                       {8, undefined}]),
    RevokedToken = rpc(mim(), mod_auth_token, token_with_mac, [HostType, RevokedToken0]),
    rpc(mim(), mod_auth_token, serialize, [RevokedToken]).

invalid_sequence_no(SeqNo) ->
    SeqNo - 1.

request_tokens_once_logged_in(Config) ->
    request_tokens_once_logged_in_impl(Config, bob).

request_tokens_once_logged_in_impl(Config, User) ->
    Self = self(),
    Ref = make_ref(),
    Fun = fun(Client) ->
              ClientShortJid = escalus_utils:get_short_jid(Client),
              R = escalus_stanza:query_el(?NS_ESL_TOKEN_AUTH, []),
              IQ = escalus_stanza:iq(ClientShortJid, <<"get">>, [R]),
              escalus:send(Client, IQ),
              Result = escalus:wait_for_stanza(Client),
              {AT, RT} = extract_tokens(Result),
              Self ! {tokens, Ref, {AT, RT}}
          end,
    escalus:story(Config, [{User, 1}], Fun),
    receive
        {tokens, Ref, Tokens} ->
            Tokens
    after
        1000 -> error
    end.

login_access_token_test(Config) ->
    Tokens = request_tokens_once_logged_in_impl(Config, bob),
    login_access_token_impl(Config, Tokens).

login_refresh_token_test(Config) ->
    Tokens = request_tokens_once_logged_in_impl(Config, bob),
    login_refresh_token_impl(Config, Tokens).

%% Scenario describing JID spoofing with an eavesdropped / stolen token.
login_with_other_users_token(Config) ->
    %% given user and another user's token
    {_, BobsToken} = request_tokens_once_logged_in_impl(Config, bob),
    AliceSpec = user_authenticating_with_token(Config, alice, BobsToken),
    %% when we try to log in
    ConnSteps = [start_stream,
                 stream_features,
                 maybe_use_ssl,
                 authenticate,
                 fun (Alice = #client{props = Props}, Features) ->
                         escalus:send(Alice, escalus_stanza:bind(<<"test-resource">>)),
                         BindReply = escalus_connection:get_stanza(Alice, bind_reply),
                         {Alice#client{props = [{bind_reply, BindReply} | Props]}, Features}
                 end],
    {ok, #client{props = Props}, _} = escalus_connection:start(AliceSpec, ConnSteps),
    %% then the server recognizes us as the other user
    LoggedInAs = extract_bound_jid(proplists:get_value(bind_reply, Props)),
    true = escalus_utils:get_username(LoggedInAs) /= escalus_users:get_username(Config, AliceSpec).

login_with_malformed_token(Config) ->
    %% given
    MalformedToken = <<"malformed ", (crypto:strong_rand_bytes(64))/bytes>>,
    %% when / then
    token_login_failure(Config, bob, MalformedToken).

login_refresh_token_impl(Config, {_AccessToken, RefreshToken}) ->
    BobSpec = escalus_users:get_userspec(Config, bob),

    ConnSteps = [start_stream,
                 stream_features,
                 maybe_use_ssl,
                 maybe_use_compression
                ],

    {ok, ClientConnection = #client{props = Props}, _Features} = escalus_connection:start(BobSpec, ConnSteps),
    Props2 = lists:keystore(oauth_token, 1, Props, {oauth_token, RefreshToken}),
    (catch escalus_auth:auth_sasl_oauth(ClientConnection, Props2)),
    ok.

%% users logs in using access token he obtained in previous session (stream has been
%% already reset)
login_access_token_impl(Config, {AccessToken, _RefreshToken}) ->
    {{ok, Props}, ClientConnection} = login_with_token(Config, bob, AccessToken),
    escalus_connection:reset_parser(ClientConnection),
    ClientConn1 = escalus_session:start_stream(ClientConnection#client{props = Props}),
    {ClientConn1, _} = escalus_session:stream_features(ClientConn1, []),
    %todo: create step out of above lines
    ClientConn2 = escalus_session:bind(ClientConn1),
    ClientConn3 = escalus_session:session(ClientConn2),
    escalus:send(ClientConn3, escalus_stanza:presence(<<"available">>)),
    escalus:assert(is_presence, escalus:wait_for_stanza(ClientConn3)).

login_with_token(Config, User, Token) ->
    UserSpec = escalus_users:get_userspec(Config, User),
    ConnSteps = [start_stream,
                 stream_features,
                 maybe_use_ssl,
                 maybe_use_compression],
    {ok, ClientConnection = #client{props = Props}, _Features} = escalus_connection:start(UserSpec, ConnSteps),
    Props2 = lists:keystore(oauth_token, 1, Props, {oauth_token, Token}),
    AuthResult = (catch escalus_auth:auth_sasl_oauth(ClientConnection, Props2)),
    {AuthResult, ClientConnection}.

token_revocation_test(Config) ->
    %% given
    {Owner, _SeqNoToRevoke, Token} = get_owner_seqno_to_revoke(Config, bob),
    %% when
    ok = revoke_token(Owner),
    %% then
    token_login_failure(Config, bob, Token).

get_owner_seqno_to_revoke(Config, User) ->
    {_, RefreshToken} = request_tokens_once_logged_in_impl(Config, User),
    [_, BOwner, _, SeqNo, _] = binary:split(RefreshToken, <<0>>, [global]),
    Owner = jid:from_binary(BOwner),
    {Owner, binary_to_integer(SeqNo), RefreshToken}.

revoke_token(Owner) ->
    rpc(mim(), mod_auth_token, revoke, [domain_helper:host_type(), Owner]).

token_removed_on_user_removal(Config) ->
    %% given existing user with token and XMPP (de)registration available
    _Tokens = request_tokens_once_logged_in_impl(Config, bob),
    true = is_xmpp_registration_available(domain_helper:host_type()),
    %% when user account is deleted
    S = fun (Bob) ->
                IQ = escalus_stanza:remove_account(),
                escalus:send(Bob, IQ),
                escalus:assert(is_iq_result, [IQ], escalus:wait_for_stanza(Bob))
        end,
    escalus:story(Config, [{bob, 1}], S),
    %% then token database doesn't contain user's tokens (cleanup is done after IQ result)
    wait_helper:wait_until(fun() -> get_users_token(Config, bob) end, {selected, []}).

provision_token_login(Config) ->
    %% given
    VCard = make_vcard(Config, bob),
    ProvisionToken = make_provision_token(Config, bob, VCard),
    UserSpec = user_authenticating_with_token(Config, bob, ProvisionToken),
    %% when logging in with provision token
    {ok, Conn, _} = escalus_connection:start(UserSpec),
    escalus:send(Conn, escalus_stanza:vcard_request()),
    %% then user's vcard is placed into the database on login
    Result = escalus:wait_for_stanza(Conn),
    VCard = exml_query:subelement(Result, <<"vCard">>).


check_for_oauth_with_mod_auth_token_not_loaded(Config) ->
    AliceSpec = escalus_users:get_userspec(Config, alice),
    ConnSteps = [start_stream,
                 stream_features,
                 maybe_use_ssl,
                 maybe_use_compression],
    {ok, _, Features} = escalus_connection:start(AliceSpec, ConnSteps),
    false = lists:member(<<"X-OAUTH">>, proplists:get_value(sasl_mechanisms,
                                                           Features, [])).

check_for_oauth_with_mod_auth_token_loaded(Config) ->
    AliceSpec = escalus_users:get_userspec(Config, alice),
    ConnSteps = [start_stream,
                 stream_features,
                 maybe_use_ssl,
                 maybe_use_compression],
    {ok, _, Features} = escalus_connection:start(AliceSpec, ConnSteps),
    true = lists:member(<<"X-OAUTH">>, proplists:get_value(sasl_mechanisms,
                                                           Features, [])).


%%
%% Helpers
%%

extract_tokens(#xmlel{name = <<"iq">>, children = [#xmlel{name = <<"items">>} = Items ]}) ->
    ATD = exml_query:path(Items, [{element, <<"access_token">>}, cdata]),
    RTD = exml_query:path(Items, [{element, <<"refresh_token">>}, cdata]),
    {base64:decode(ATD), base64:decode(RTD)}.

assert_password_format(GroupName, Config) ->
    Users = proplists:get_value(escalus_users, Config),
    [verify_format(GroupName, User) || User <- Users],
    Config.

verify_format(GroupName, {_User, Props}) ->
    Username = escalus_utils:jid_to_lower(proplists:get_value(username, Props)),
    Server = proplists:get_value(server, Props),
    Password = proplists:get_value(password, Props),
    JID = mongoose_helper:make_jid(Username, Server),
    {SPassword, _} = rpc(mim(), ejabberd_auth, get_passterm_with_authmodule,
                         [domain_helper:host_type(), JID]),
    do_verify_format(GroupName, Password, SPassword).

do_verify_format(login_scram, _Password, SPassword) ->
    %% returned password is a tuple containing scram data
    {_, _, _, _} = SPassword;
do_verify_format(_, Password, SPassword) ->
    Password = SPassword.

%% @doc Set Fields of the Record to Values,
%% when {Field, Value} <- FieldValues (in list comprehension syntax).
record_set(Record, FieldValues) ->
    F = fun({Field, Value}, Rec) ->
                setelement(Field, Rec, Value)
        end,
    lists:foldl(F, Record, FieldValues).

mimctl(Config, CmdAndArgs) ->
    Node = ct:get_config({hosts, mim, node}),
    ejabberd_node_utils:call_ctl_with_args(Node, convert_args(CmdAndArgs), Config).

convert_args(Args) -> [ convert_arg(A) || A <- Args ].

convert_arg(B) when is_binary(B) -> binary_to_list(B);
convert_arg(A) when is_atom(A) -> atom_to_list(A);
convert_arg(S) when is_list(S) -> S.

clean_token_db() ->
    Q = [<<"DELETE FROM auth_token">>],
    {updated, _} = rpc(mim(), mongoose_rdbms, sql_query, [domain_helper:host_type(), Q]).

get_users_token(C, User) ->
    Q = ["SELECT * FROM auth_token at "
         "WHERE at.owner = '", to_lower(escalus_users:get_jid(C, User)), "';"],
    rpc(mim(), mongoose_rdbms, sql_query, [escalus_users:get_server(C, User), Q]).

is_xmpp_registration_available(Domain) ->
    rpc(mim(), gen_mod, is_loaded, [Domain, mod_register]).

user_authenticating_with_token(Config, UserName, Token) ->
    Spec1 = lists:keystore(oauth_token, 1, escalus_users:get_userspec(Config, UserName),
                           {oauth_token, Token}),
    lists:keystore(auth, 1, Spec1, {auth, fun escalus_auth:auth_sasl_oauth/2}).

extract_bound_jid(BindReply) ->
    exml_query:path(BindReply, [{element, <<"bind">>}, {element, <<"jid">>},
                                cdata]).

get_provision_key(Domain) ->
    RPCArgs = [Domain, provision_pre_shared],
    [{_, RawKey}] = rpc(mim(), mongoose_hooks, get_key, RPCArgs),
    RawKey.

make_vcard(Config, User) ->
    T = <<"<vCard xmlns='vcard-temp'>"
          "<FN>Full Name</FN>"
          "<NICKNAME>{{nick}}</NICKNAME>"
          "</vCard>">>,
    escalus_stanza:from_template(T, [{nick, escalus_users:get_username(Config, User)}]).

make_provision_token(Config, User, VCard) ->
    ExpiryFarInTheFuture = {{2055, 10, 27}, {10, 54, 22}},
    Username = escalus_users:get_username(Config, User),
    Domain = escalus_users:get_server(Config, User),
    ServerSideJID = jid:make(Username, Domain, <<>>),
    T0 = {token, provision,
          ExpiryFarInTheFuture,
          ServerSideJID,
          %% sequence no
          undefined,
          VCard,
          %% MAC
          undefined,
          %% body
          undefined},
    T = rpc(mim(), mod_auth_token, token_with_mac, [domain_helper:host_type(), T0]),
    %% assert no RPC error occured
    {token, provision} = {element(1, T), element(2, T)},
    serialize(T).

serialize(ServerSideToken) ->
    Serialized = rpc(mim(), mod_auth_token, serialize, [ServerSideToken]),
    case is_binary(Serialized) of
        true -> Serialized;
        false -> error(Serialized)
    end.

to_lower(B) when is_binary(B) ->
    string:lowercase(B).

required_modules() ->
    KeyOpts = #{backend => ct_helper:get_internal_database(),
                keys => #{token_secret => ram,
                         %% This is a hack for tests! As the name implies,
                         %% a pre-shared key should be read from a file stored
                         %% on disk. This way it can be shared with trusted 3rd
                         %% parties who can use it to sign tokens for users
                         %% to authenticate with and MongooseIM to verify.
                         provision_pre_shared => ram}},
    KeyStoreOpts = config_parser_helper:mod_config(mod_keystore, KeyOpts),
    [{mod_last, stopped},
     {mod_keystore, KeyStoreOpts},
     {mod_auth_token, auth_token_opts()}].

auth_token_opts() ->
    Defaults = config_parser_helper:default_mod_config(mod_auth_token),
    Defaults#{validity_period => #{access => #{value => 60, unit => minutes},
                                   refresh => #{value => 1, unit => days}}}.
