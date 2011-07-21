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

-module(couch_httpd_view_merger).

-export([handle_req/1]).

-include("couch_db.hrl").
-include("couch_view_merger.hrl").
-include("../ibrowse/ibrowse.hrl").

-import(couch_util, [
    get_value/2,
    get_value/3,
    to_binary/1
]).
-import(couch_httpd, [
    qs_json_value/3
]).

-record(sender_acc, {
    req = nil,
    resp = nil,
    on_error,
    acc = <<>>,
    error_acc = []
}).


handle_req(#httpd{method = 'GET'} = Req) ->
    Views = validate_views_param(qs_json_value(Req, "views", nil)),
    Keys = validate_keys_param(qs_json_value(Req, "keys", nil)),
    RedFun = validate_reredfun_param(qs_json_value(Req, <<"rereduce">>, nil)),
    RedFunLang = validate_lang_param(
        qs_json_value(Req, <<"language">>, <<"javascript">>)),
    MergeParams0 = #view_merge{
        views = Views,
        keys = Keys,
        rereduce_fun = RedFun,
        rereduce_fun_lang = RedFunLang,
        callback = fun http_sender/2
    },
    MergeParams1 = apply_http_config(Req, [], MergeParams0),
    MergeParams2 = MergeParams1#view_merge{
        user_acc = #sender_acc{
            req = Req, on_error = MergeParams1#view_merge.on_error
        }
    },
    couch_view_merger:query_view(Req, MergeParams2);

handle_req(#httpd{method = 'POST'} = Req) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    {Props} = couch_httpd:json_body_obj(Req),
    Views = validate_views_param(get_value(<<"views">>, Props)),
    Keys = validate_keys_param(get_value(<<"keys">>, Props, nil)),
    RedFun = validate_reredfun_param(get_value(<<"rereduce">>, Props, nil)),
    RedFunLang = validate_lang_param(
        get_value(<<"language">>, Props, <<"javascript">>)),
    MergeParams0 = #view_merge{
        views = Views,
        keys = Keys,
        rereduce_fun = RedFun,
        rereduce_fun_lang = RedFunLang,
        callback = fun http_sender/2
    },
    MergeParams1 = apply_http_config(Req, Props, MergeParams0),
    MergeParams2 = MergeParams1#view_merge{
        user_acc = #sender_acc{
            req = Req, on_error = MergeParams1#view_merge.on_error
        }
    },
    couch_view_merger:query_view(Req, MergeParams2);

handle_req(Req) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST").


apply_http_config(Req, Body, MergeParams) ->
    DefConnTimeout = MergeParams#view_merge.conn_timeout,
    ConnTimeout = case get_value(<<"connection_timeout">>, Body, nil) of
    nil ->
        qs_json_value(Req, "connection_timeout", DefConnTimeout);
    T when is_integer(T) ->
        T
    end,
    OnError = case get_value(<<"on_error">>, Body, nil) of
    nil ->
       qs_json_value(Req, "on_error", <<"continue">>);
    Policy when is_binary(Policy) ->
       Policy
    end,
    MergeParams#view_merge{
        conn_timeout = ConnTimeout,
        on_error = validate_on_error_param(OnError)
    }.


http_sender(start, #sender_acc{req = Req, error_acc = ErrorAcc} = SAcc) ->
    {ok, Resp} = couch_httpd:start_json_response(Req, 200, []),
    couch_httpd:send_chunk(Resp, <<"{\"rows\":[">>),
    case ErrorAcc of
    [] ->
        Acc = <<"\r\n">>;
    _ ->
        lists:foreach(
            fun(Row) -> couch_httpd:send_chunk(Resp, [Row, <<",\r\n">>]) end,
            lists:reverse(ErrorAcc)),
        Acc = <<>>
    end,
    {ok, SAcc#sender_acc{resp = Resp, acc = Acc}};

http_sender({start, RowCount}, #sender_acc{req = Req, error_acc = ErrorAcc} = SAcc) ->
    Start = io_lib:format(
        "{\"total_rows\":~w,\"rows\":[", [RowCount]),
    {ok, Resp} = couch_httpd:start_json_response(Req, 200, []),
    couch_httpd:send_chunk(Resp, Start),
    case ErrorAcc of
    [] ->
        Acc = <<"\r\n">>;
    _ ->
        lists:foreach(
            fun(Row) -> couch_httpd:send_chunk(Resp, [Row, <<",\r\n">>]) end,
            lists:reverse(ErrorAcc)),
        Acc = <<>>
    end,
    {ok, SAcc#sender_acc{resp = Resp, acc = Acc, error_acc = []}};

http_sender({row, Row}, #sender_acc{resp = Resp, acc = Acc} = SAcc) ->
    couch_httpd:send_chunk(Resp, [Acc, ?JSON_ENCODE(Row)]),
    {ok, SAcc#sender_acc{acc = <<",\r\n">>}};

http_sender(stop, #sender_acc{resp = Resp}) ->
    couch_httpd:send_chunk(Resp, <<"\r\n]}">>),
    {ok, couch_httpd:end_json_response(Resp)};

http_sender({error, Url, Reason}, #sender_acc{on_error = continue} = SAcc) ->
    #sender_acc{resp = Resp, error_acc = ErrorAcc, acc = Acc} = SAcc,
    Row = {[
        {<<"error">>, true}, {<<"from">>, rem_passwd(Url)},
        {<<"reason">>, to_binary(Reason)}
    ]},
    case Resp of
    nil ->
        % we haven't started the response yet
        ErrorAcc2 = [?JSON_ENCODE(Row) | ErrorAcc],
        Acc2 = Acc;
    _ ->
        couch_httpd:send_chunk(Resp, [Acc, ?JSON_ENCODE(Row)]),
        ErrorAcc2 = ErrorAcc,
        Acc2 = <<",\r\n">>
    end,
    {ok, SAcc#sender_acc{error_acc = ErrorAcc2, acc = Acc2}};

http_sender({error, Url, Reason}, #sender_acc{on_error = stop} = SAcc) ->
    #sender_acc{req = Req, resp = Resp, acc = Acc} = SAcc,
    Row = {[
        {<<"error">>, true}, {<<"from">>, rem_passwd(Url)},
        {<<"reason">>, to_binary(Reason)}
    ]},
    case Resp of
    nil ->
        % we haven't started the response yet
        Start = io_lib:format("{\"total_rows\":~w,\"rows\":[\r\n", [0]),
        {ok, Resp2} = couch_httpd:start_json_response(Req, 200, []),
        couch_httpd:send_chunk(Resp2, Start),
        couch_httpd:send_chunk(Resp2, ?JSON_ENCODE(Row)),
        couch_httpd:send_chunk(Resp2, <<"\r\n]}">>);
    _ ->
       Resp2 = Resp,
       couch_httpd:send_chunk(Resp2, [Acc, ?JSON_ENCODE(Row)]),
       couch_httpd:send_chunk(Resp2, <<"\r\n]}">>)
    end,
    {stop, Resp2}.


%% Valid `views` example:
%%
%% {
%%   "views": {
%%     "localdb1": ["ddocname/viewname", ...],
%%     "http://server2/dbname": ["ddoc/view"],
%%     "http://server2/_view_merge": {
%%       "views": {
%%         "localdb3": "viewname", // local to server2
%%         "localdb4": "viewname"  // local to server2
%%       }
%%     }
%%   }
%% }

validate_views_param({[_ | _] = Views}) ->
    lists:flatten(lists:map(
        fun({DbName, ViewName}) when is_binary(ViewName) ->
            {DDocId, Vn} = parse_view_name(ViewName),
            #simple_view_spec{
                database = DbName, ddoc_id = DDocId, view_name = Vn
            };
        ({DbName, ViewNames}) when is_list(ViewNames) ->
            lists:map(
                fun(ViewName) ->
                    {DDocId, Vn} = parse_view_name(ViewName),
                    #simple_view_spec{
                        database = DbName, ddoc_id = DDocId, view_name = Vn
                    }
                end, ViewNames);
        ({MergeUrl, {[_ | _] = Props} = EJson}) ->
            case (catch ibrowse_lib:parse_url(?b2l(MergeUrl))) of
            #url{} ->
                ok;
            _ ->
                throw({bad_request, "Invalid view merge definition object."})
            end,
            case get_value(<<"views">>, Props) of
            {[_ | _]} = SubViews ->
                SubViewSpecs = validate_views_param(SubViews),
                case lists:any(
                    fun(#simple_view_spec{}) -> true; (_) -> false end,
                    SubViewSpecs) of
                true ->
                    ok;
                false ->
                    SubMergeError = io_lib:format("Could not find a non-composed"
                        " view spec in the view merge targeted at `~s`",
                        [rem_passwd(MergeUrl)]),
                    throw({bad_request, SubMergeError})
                end,
                #merged_view_spec{url = MergeUrl, ejson_spec = EJson};
            _ ->
                SubMergeError = io_lib:format("Invalid view merge definition for"
                    " sub-merge done at `~s`.", [rem_passwd(MergeUrl)]),
                throw({bad_request, SubMergeError})
            end;
        (_) ->
            throw({bad_request, "Invalid view merge definition object."})
        end, Views));

validate_views_param(_) ->
    throw({bad_request, <<"`views` parameter must be an object with at ",
                          "least 1 property.">>}).

parse_view_name(Name) ->
    case string:tokens(couch_util:trim(?b2l(Name)), "/") of
    ["_all_docs"] ->
        {nil, <<"_all_docs">>};
    [DDocName, ViewName0] ->
        {<<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    ["_design", DDocName, ViewName0] ->
        {<<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    _ ->
        throw({bad_request, "A `view` property must have the shape"
            " `ddoc_name/view_name`."})
    end.


validate_keys_param(nil) ->
    nil;
validate_keys_param(Keys) when is_list(Keys) ->
    Keys;
validate_keys_param(_) ->
    throw({bad_request, "`keys` parameter is not an array."}).


validate_reredfun_param(nil) ->
    nil;
validate_reredfun_param(RedFun) when is_binary(RedFun) ->
    RedFun;
validate_reredfun_param(_) ->
    throw({bad_request, "`rereduce` parameter is not a string."}).


validate_lang_param(Lang) when is_binary(Lang) ->
    Lang;
validate_lang_param(_) ->
    throw({bad_request, "`language` parameter is not a string."}).


validate_on_error_param(<<"continue">>) ->
    continue;
validate_on_error_param(<<"stop">>) ->
    stop;
validate_on_error_param(Value) ->
    Msg = io_lib:format("Invalid value (`~s`) for the parameter `on_error`."
        " It must be `continue` (default) or `stop`.", [to_binary(Value)]),
    throw({bad_request, Msg}).


rem_passwd(Url) ->
    ?l2b(couch_util:url_strip_password(Url)).
