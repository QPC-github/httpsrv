:- module httpsrv.

% Copyright (C) 2014 YesLogic Pty. Ltd.
% All rights reserved.

:- interface.

:- import_module assoc_list.
:- import_module io.
:- import_module list.
:- import_module maybe.
:- import_module pair.

:- import_module headers.

:- include_module httpsrv.status.
:- import_module httpsrv.status.

%-----------------------------------------------------------------------------%

:- type daemon.
:- type client.

:- type server_setting
    --->    bind_address(string)
    ;       port(int)
    ;       back_log(int).

:- type request_handler == pred(client, request, io, io).
:- inst request_handler == (pred(in, in, di, uo) is cc_multi).

:- type request
    --->    request(
                method      :: method,
                url_raw     :: string, % mainly for debugging
                url         :: url,
                path_decoded:: maybe(string), % percent decoded
                query_params:: assoc_list(string), % percent decoded
                headers     :: headers,
                cookies     :: assoc_list(string),
                body        :: content
            ).

:- type method
    --->    delete
    ;       get
    ;       head
    ;       post
    ;       put
    ;       other(string).

:- type url
    --->    url(
                schema      :: maybe(string),
                host        :: maybe(string),
                port        :: maybe(string),
                path_raw    :: maybe(string),
                query_raw   :: maybe(string),
                fragment    :: maybe(string)
            ).

:- type content
    --->    none
    ;       string(string)

            % For application/x-www-form-urlencoded
            % Keys are in RECEIVED order and duplicate keys are possible.
    ;       form_urlencoded(assoc_list(string, string))

            % For multipart/form-data
            % Keys are in RECEIVED order and duplicate keys are possible.
    ;       multipart_formdata(assoc_list(string, formdata)).

:- type formdata
    --->    formdata(
                disposition                 :: string,
                filename                    :: maybe(string),
                media_type                  :: string,
                content_transfer_encoding   :: maybe(string),
                content                     :: formdata_content
            ).

:- type formdata_content.

:- pred setup(request_handler::in(request_handler), list(server_setting)::in,
    maybe_error(daemon)::out, io::di, io::uo) is det.

:- pred run(daemon::in, io::di, io::uo) is det.

:- type response_content
    --->    strings(list(string))
    ;       file(static_file).

    % NOTE: for now, the user is responsible for any necessary escaping!
    %
:- type response_header
    --->    cache_control_max_age(int)
    ;       content_type(string)
    ;       content_type_charset_utf8(string)
    ;       content_disposition(string)
    ;       set_cookie(pair(string), assoc_list(string))
    ;       x_content_type_options_nosniff
    ;       custom(pair(string), assoc_list(string)).

:- pred set_response(client::in, request::in, status_code::in,
    list(response_header)::in, response_content::in, io::di, io::uo) is det.

:- type static_file.

:- pred open_static_file(string::in, maybe_error(static_file)::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module bool.
:- import_module cord.
:- import_module int.
:- import_module string.
:- import_module time.

:- import_module buffer.
:- import_module http_date.
:- import_module mime_headers.
:- import_module multipart_parser.
:- import_module urlencoding.
:- use_module rfc6265.

:- include_module httpsrv.formdata_accum.
:- include_module httpsrv.parse_url.
:- include_module httpsrv.response.
:- import_module httpsrv.formdata_accum.
:- import_module httpsrv.parse_url.
:- import_module httpsrv.response.

%-----------------------------------------------------------------------------%

:- pragma foreign_type("C", daemon, "daemon_t *").
:- pragma foreign_type("C", client, "client_t *").

:- pragma foreign_decl("C", "
    typedef struct daemon daemon_t;
    typedef struct client client_t;
    typedef struct buffer buffer_t;
").

:- pragma foreign_decl("C", local, "
    #include ""uv.h""
    #include ""http_parser.h""

    #include ""httpsrv1.h""
").

:- pragma foreign_code("C", "
    #include ""httpsrv1.c""
").

:- type formdata_content == list(buffer).

:- type static_file
    --->    static_file(
                fd          :: int,
                file_size   :: int
            ).

%-----------------------------------------------------------------------------%

setup(RequestHandler, Settings, Res, !IO) :-
    FindStr = find(Settings),
    FindInt = find(Settings),
    BindAddress = FindStr(pred(bind_address(X)::in, X::out) is semidet, "127.0.0.1"),
    Port = FindInt(pred(port(X)::in, X::out) is semidet, 80),
    BackLog = FindInt(pred(back_log(X)::in, X::out) is semidet, 1),

    setup_2(RequestHandler, BindAddress, Port, BackLog, Daemon, Ok, !IO),
    (
        Ok = yes,
        Res = ok(Daemon)
    ;
        Ok = no,
        % XXX better error message
        Res = error("(no error details yet)")
    ).

:- pred setup_2(request_handler::in(request_handler),
    string::in, int::in, int::in, daemon::out, bool::out, io::di, io::uo)
    is det.

:- pragma foreign_proc("C",
    setup_2(RequestHandler::in(request_handler),
        BindAddress::in, Port::in, BackLog::in,
        Daemon::out, Ok::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    Daemon = daemon_setup(RequestHandler, BindAddress, Port, BackLog);
    Ok = (Daemon) ? MR_YES : MR_NO;
").

:- func find(list(T)::in, pred(T, X)::in(pred(in, out) is semidet), X::in)
    = (X::out) is det.

find([], _P, Default) = Default.
find([T | Ts], P, Default) =
    ( P(T, X) ->
        X
    ;
        find(Ts, P, Default)
    ).

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    run(Daemon::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    uv_run(Daemon->loop, UV_RUN_DEFAULT);
    daemon_cleanup(Daemon);
").

%-----------------------------------------------------------------------------%

set_response(Client, Request, Status, AdditionalHeaders, Content, !IO) :-
    time(Time, !IO),
    HttpDate = timestamp_to_http_date(Time),
    KeepAlive = client_should_keep_alive(Client),
    (
        KeepAlive = yes,
        MaybeConnectionClose = ""
    ;
        KeepAlive = no,
        MaybeConnectionClose = "Connection: close\r\n"
    ),
    (
        Content = strings(ContentStrings),
        ContentLength = sum_length(ContentStrings),
        ( skip_body(Request) ->
            Body = cord.init
        ;
            Body = cord.from_list(ContentStrings)
        ),
        FileFd = -1,
        FileSize = 0
    ;
        Content = file(StaticFile),
        ContentLength = StaticFile ^ file_size,
        Body = cord.init,
        ( skip_body(Request) ->
            close_static_file(StaticFile, !IO),
            FileFd = -1,
            FileSize = 0
        ;
            StaticFile = static_file(FileFd, FileSize)
        )
    ),

    HeaderPre = cord.from_list([
        "HTTP/1.1 ", text(Status), "\r\n",
        "Date: ", HttpDate, "\r\n"
    ]),
    HeaderMid = list.map(render_response_header, AdditionalHeaders),
    HeaderPost = cord.from_list([
        "Content-Length: ", from_int(ContentLength), "\r\n",
        MaybeConnectionClose,
        "\r\n"
    ]),
    ResponseCord = HeaderPre ++ cord_list_to_cord(HeaderMid) ++ HeaderPost ++
        Body,
    ResponseList = cord.list(ResponseCord),
    set_response_2(Client, ResponseList, length(ResponseList),
        FileFd, FileSize, !IO).

:- pred set_response_2(client::in, list(string)::in, int::in,
    int::in, int::in, io::di, io::uo) is det.

:- pragma foreign_proc("C",
    set_response_2(Client::in, ResponseList::in, ResponseListLength::in,
        FileFd::in, FileLength::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    set_response_bufs(Client, ResponseList, ResponseListLength,
        FileFd, FileLength);
    send_async(Client);
").

:- pred skip_body(request::in) is semidet.

skip_body(Request) :-
    Request ^ method = head.

:- func sum_length(list(string)) = int.

sum_length(Xs) = foldl(plus, map(length, Xs), 0).

%-----------------------------------------------------------------------------%

% Mercury to C

:- func request_init = request.

:- pragma foreign_export("C", request_init = out, "request_init").

request_init =
    request(other(""), "", url_init, no, [], init_headers, [], none).

:- func url_init = url.

url_init = url(no, no, no, no, no, no).

:- func request_add_header(request, string, string) = request.

:- pragma foreign_export("C", request_add_header(in, in, in) = out,
    "request_add_header").

request_add_header(Req0, Name, Body) = Req :-
    Req0 ^ headers = Headers0,
    add_header(Name, Body, Headers0, Headers),
    Req = Req0 ^ headers := Headers.

:- func request_get_expect_header(request) = int.

:- pragma foreign_export("C", request_get_expect_header(in) = out,
    "request_get_expect_header").

request_get_expect_header(Req) = Result :-
    Headers = Req ^ headers,
    ( search_field(Headers, "Expect", Body) ->
        % Strictly speaking the expectation value can be a comma separated list
        % and "100-continue" is one of the possible elements of that list.
        % But at least HTTP field values may NOT have comments unless
        % specifically stated (unlike RFC 822).
        ( string_equal_ci(Body, "100-continue") ->
            Result = 1
        ;
            Result = -1
        )
    ;
        Result = 0
    ).

:- pred request_prepare(string::in, string::in, request::in, request::out)
    is semidet.

:- pragma foreign_export("C", request_prepare(in, in, in, out),
    "request_prepare").

request_prepare(MethodString, UrlString, !Req) :-
    request_set_method(MethodString, !Req),
    request_set_url(UrlString, !Req),
    request_set_cookies(!Req).

:- pred request_set_method(string::in, request::in, request::out) is det.

request_set_method(MethodString, !Req) :-
    ( method(MethodString, Method) ->
        !Req ^ method := Method
    ;
        !Req ^ method := other(MethodString)
    ).

:- pred method(string, method).
:- mode method(in, out) is semidet.
:- mode method(out, in) is semidet.

method("DELETE", delete).
method("GET", get).
method("HEAD", head).
method("POST", post).
method("PUT", put).

:- pred request_set_url(string::in, request::in, request::out) is semidet.

request_set_url(UrlString, !Req) :-
    !Req ^ url_raw := UrlString,
    ( UrlString = "*" ->
        % Request applies to the server and not a resource.
        % Maybe we could add an option for this.
        true
    ;
        parse_url_and_host_header(!.Req ^ headers, UrlString, Url),
        require_det (
            decode_path(Url, MaybePathDecoded),
            decode_query_parameters(Url, QueryParams),
            !Req ^ url := Url,
            !Req ^ path_decoded := MaybePathDecoded,
            !Req ^ query_params := QueryParams
        )
    ).

:- pred request_set_cookies(request::in, request::out) is det.

request_set_cookies(!Req) :-
    % Parse all Cookie: header values, dropping anything we can't recognise.
    search_field_multi(!.Req ^ headers, "Cookie", CookieHeaderValues),
    list.filter_map(rfc6265.parse_cookie_header_value, CookieHeaderValues,
        Cookiess),
    list.condense(Cookiess, Cookies),
    !Req ^ cookies := Cookies.

:- func request_set_body_stringish(request, string) = request.

:- pragma foreign_export("C", request_set_body_stringish(in, in) = out,
    "request_set_body_stringish").

request_set_body_stringish(Req0, String) = Req :-
    Headers = Req0 ^ headers,
    (
        get_content_type(Headers, MediaType, _Params),
        media_type_equals(MediaType, application_x_www_form_urlencoded),
        parse_form_urlencoded(String, Form)
    ->
        Body = form_urlencoded(Form)
    ;
        Body = string(String)
    ),
    Req = Req0 ^ body := Body.

:- func application_x_www_form_urlencoded = string.

application_x_www_form_urlencoded = "application/x-www-form-urlencoded".

:- pred request_search_multipart_formdata_boundary(request::in, string::out)
    is semidet.

:- pragma foreign_export("C",
    request_search_multipart_formdata_boundary(in, out),
    "request_search_multipart_formdata_boundary").

request_search_multipart_formdata_boundary(Req, Boundary) :-
    Headers = Req ^ headers,
    % XXX report errors, reject other multipart types
    is_multipart_content_type(Headers, MaybeMultiPart),
    MaybeMultiPart = multipart(MediaType, Boundary),
    media_type_equals(MediaType, multipart_formdata).

:- func multipart_formdata = string.

multipart_formdata = "multipart/form-data".

:- func create_formdata_parser(string) = multipart_parser(formdata_accum).

:- pragma foreign_export("C", create_formdata_parser(in) = out,
    "create_formdata_parser").

create_formdata_parser(Boundary) =
    multipart_parser.init(Boundary, formdata_accum.init).

:- pred parse_formdata(buffer::in, int::in, int::out,
    multipart_parser(formdata_accum)::in, multipart_parser(formdata_accum)::out,
    bool::out, string::out, io::di, io::uo) is det.

:- pragma foreign_export("C",
    parse_formdata(in, in, out, in, out, out, out, di, uo),
    "parse_formdata").

parse_formdata(Buf, !BufPos, !PS, IsError, ErrorString, !IO) :-
    multipart_parser.execute(Buf, !BufPos, !PS, !IO),
    multipart_parser.get_error(!.PS, MaybeError),
    (
        MaybeError = ok,
        IsError = no,
        ErrorString = ""
    ;
        MaybeError = error(ErrorString),
        IsError = yes
    ).

:- func request_set_body_formdata(request, multipart_parser(formdata_accum))
    = request.

:- pragma foreign_export("C", request_set_body_formdata(in, in) = out,
    "request_set_body_formdata").

request_set_body_formdata(Req0, PS) = Req :-
    Parts = get_parts(get_userdata(PS)),
    Req = Req0 ^ body := multipart_formdata(Parts).

:- pred call_request_handler_pred(request_handler::in(request_handler),
    client::in, request::in, io::di, io::uo) is cc_multi.

:- pragma foreign_export("C",
    call_request_handler_pred(in(request_handler), in, in, di, uo),
    "call_request_handler_pred").

call_request_handler_pred(Pred, Client, Request, !IO) :-
    call(Pred, Client, Request, !IO).

%-----------------------------------------------------------------------------%

% C to Mercury

:- func client_should_keep_alive(client) = bool.

:- pragma foreign_proc("C",
    client_should_keep_alive(Client::in) = (KeepAlive::out),
    [will_not_call_mercury, promise_pure, thread_safe, may_not_duplicate],
"
    KeepAlive = (Client->should_keep_alive) ? MR_YES : MR_NO;
").

%-----------------------------------------------------------------------------%

% Static file

open_static_file(Path, Result, !IO) :-
    open_static_file_2(Path, Fd, Size, Error, !IO),
    ( Fd < 0 ->
        Result = error(Error)
    ;
        Result = ok(static_file(Fd, Size))
    ).

:- pred open_static_file_2(string::in, int::out, int::out, string::out,
    io::di, io::uo) is det.

:- pragma foreign_proc("C",
    open_static_file_2(Path::in, Fd::out, Size::out, Error::out,
        _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    struct stat st;

    Fd = -1;
    Size = 0;

    if (stat(Path, &st) < 0) {
        Error = MR_make_string_const(""stat failed"");
    } else if (! S_ISREG(st.st_mode)) {
        Error = MR_make_string_const(""not regular file"");
    } else {
        Fd = open(Path, O_RDONLY);
        if (Fd < 0) {
            Error = MR_make_string_const(""open failed"");
        } else {
            Size = st.st_size;
        }
    }
").

:- pred close_static_file(static_file::in, io::di, io::uo) is det.

close_static_file(static_file(Fd, _Size), !IO) :-
    close_static_file_2(Fd, !IO).

:- pred close_static_file_2(int::in, io::di, io::uo) is det.

:- pragma foreign_proc("C",
    close_static_file_2(Fd::in, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, thread_safe, tabled_for_io,
        may_not_duplicate],
"
    close(Fd);
").

%-----------------------------------------------------------------------------%

% Utilities

:- pred string_equal_ci(string::in, string::in) is semidet.

string_equal_ci(A, B) :-
    string.to_lower(A, Lower),
    string.to_lower(B, Lower).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
