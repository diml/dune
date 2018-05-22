open Import
open Sexp.Of_sexp

module Lang = struct
  type t =
    | Jbuilder
    | Dune of Syntax.Version.t

  let latest = Dune (0, 1)
end

module Name : sig
  type t = private
    | Named     of string
    | Anonymous of Path.t

  val compare : t -> t -> Ordering.t

  val to_string_hum : t -> string

  val named_of_sexp : t Sexp.Of_sexp.t
  val sexp_of_t : t Sexp.To_sexp.t

  val encode : t -> string
  val decode : string -> t

  val anonymous : Path.t -> t option
  val named : string -> t option

  val anonymous_root : t
end = struct
  type t =
    | Named     of string
    | Anonymous of Path.t

  let anonymous_root = Anonymous Path.root

  let compare a b =
    match a, b with
    | Named     x, Named     y -> String.compare x y
    | Anonymous x, Anonymous y -> Path.compare   x y
    | Named     _, Anonymous _ -> Lt
    | Anonymous _, Named     _ -> Gt

  let to_string_hum = function
    | Named     s -> s
    | Anonymous p -> sprintf "<anonymous %s>" (Path.to_string_maybe_quoted p)

  let sexp_of_t = function
    | Named s -> Sexp.To_sexp.string s
    | Anonymous p ->
      List [ Sexp.unsafe_atom_of_string "anonymous"
           ; Path.sexp_of_t p
           ]

  let validate name =
    let len = String.length name in
    len > 0 &&
    String.for_all name ~f:(function
      | '.' | '/' -> false
      | _         -> true)

  let named name =
    if validate name then
      Some (Named name)
    else
      None

  let anonymous path =
    if Path.is_managed path then
      Some (Anonymous path)
    else
      None

  let named_of_sexp sexp =
    let s = string sexp in
    if validate s then
      Named s
    else
      of_sexp_error sexp "invalid project name"

  let encode = function
    | Named     s -> s
    | Anonymous p ->
      if Path.is_root p then
        "."
      else
        "." ^ String.map (Path.to_string p)
                ~f:(function
                  | '/' -> '.'
                  | c   -> c)

  let decode =
    let invalid s =
      (* Users would see this error if they did "dune build
         _build/default/.ppx/..." *)
      die "Invalid encoded project name: %S" s
    in
    fun s ->
      match s with
      | "" -> invalid s
      | "." -> anonymous_root
      | _ when s.[0] = '.' ->
        let p =
          Path.of_string
            (String.split s ~on:'.'
             |> List.tl
             |> String.concat ~sep:"/")
        in
        if not (Path.is_managed p) then invalid s;
        Anonymous p
      | _ when validate s -> Named s
      | _ -> invalid s
end

type t =
  { lang          : Lang.t
  ; name          : Name.t
  ; root          : Path.t
  ; version       : string option
  ; packages      : Package.t Package.Name.Map.t
  ; stanza_parser : Stanza.t Sexp.Of_sexp.t
  }

let anonymous =
  { lang          = Lang.latest
  ; name          = Name.anonymous_root
  ; packages      = Package.Name.Map.empty
  ; root          = Path.root
  ; version       = None
  ; stanza_parser = Sexp.Of_sexp.sum []
  }

module Extension = struct
  module One_version = struct
    module Info = struct
      type t =
        { stanzas : Stanza.t Sexp.Of_sexp.Constructor_spec.t list
        }

      let make ?(stanzas=[]) () = { stanzas }
    end

    type parser =
        Parser : ('a, Info.t) Sexp.Of_sexp.Constructor_args_spec.t * 'a
          -> parser

    type t = Syntax.Version.t * parser

    let make ver args_spec f =
      (ver, Parser (args_spec, f))
  end

  let extensions = Hashtbl.create 32

  let register name versions =
    if Hashtbl.mem extensions name then
      Exn.code_error "Dune_project.Extension.register: already registered"
        [ "name", Sexp.To_sexp.string name ];
    Hashtbl.add extensions name (Syntax.Versioned_parser.make versions)

  let parse entries =
    match String.Map.of_list entries with
    | Error (name, _, (loc, _, _)) ->
      Loc.fail loc "Exntesion %S specified for the second time." name
    | Ok _ ->
      List.concat_map entries ~f:(fun (name, (loc, (ver_loc, ver), args)) ->
        match Hashtbl.find extensions name with
        | None -> Loc.fail loc "Unknown extension %S." name
        | Some versions ->
          let (One_version.Parser (spec, f)) =
            Syntax.Versioned_parser.find_exn versions
              ~loc:ver_loc ~data_version:ver
          in
          let info =
            Sexp.Of_sexp.Constructor_args_spec.parse spec args f
          in
          info.stanzas)
end

let filename = "dune-project"

let default_name ~dir ~packages =
  match Package.Name.Map.choose packages with
  | None -> Option.value_exn (Name.anonymous dir)
  | Some (_, pkg) ->
    let pkg =
      Package.Name.Map.fold packages ~init:pkg ~f:(fun pkg acc ->
        if acc.Package.name <= pkg.Package.name then
          acc
        else
          pkg)
    in
    let name = Package.Name.to_string pkg.name in
    match Name.named name with
    | Some x -> x
    | None ->
      Loc.fail (Loc.in_file (Path.to_string (Package.opam_file pkg)))
        "%S is not a valid opam package name."
        name

let name ~dir ~packages =
  field_o "name" Name.named_of_sexp >>= function
  | Some x -> return x
  | None -> return (default_name ~dir ~packages)

let parse ~dir packages =
  record
    (name ~dir ~packages >>= fun name ->
     field_o "version" string >>= fun version ->
     dup_field_multi "using"
       (located string
        @> located Syntax.Version.t_of_sexp
        @> cstr_loc (rest raw))
       (fun (loc, name) ver args_loc args ->
          (name, (loc, ver, Sexp.Ast.List (args_loc, args))))
     >>= fun extensions ->
     let stanzas = Extension.parse extensions in
     return { lang = Dune (0, 1)
            ; name
            ; root = dir
            ; version
            ; packages
            ; stanza_parser = Sexp.Of_sexp.sum stanzas
            })

let load_dune_project ~dir packages =
  let fname = Path.relative dir filename in
  Io.with_lexbuf_from_file fname ~f:(fun lb ->
    let { Dune_lexer. lang; version } = Dune_lexer.first_line lb in
    (match lang with
     | _, "dune" -> ()
     | loc, s ->
       Loc.fail loc "%s is not a supported langauge. \
                     Only the dune language is supported." s);
    (match version with
     | _, "0.1" -> ()
     | loc, s ->
       Loc.fail loc "Unsupported version of the dune language. \
                     The only supported version is 0.1." s);
    let sexp = Sexp.Parser.parse lb ~mode:Many_as_one in
    parse ~dir packages sexp)

let make_jbuilder_project ~dir packages =
  { lang = Jbuilder
  ; name = default_name ~dir ~packages
  ; root = dir
  ; version = None
  ; packages
  ; stanza_parser = Sexp.Of_sexp.sum []
  }

let load ~dir ~files =
  let packages =
    String.Set.fold files ~init:[] ~f:(fun fn acc ->
      match Filename.split_extension fn with
      | (pkg, ".opam") when pkg <> "" ->
        let version_from_opam_file =
          let opam = Opam_file.load (Path.relative dir fn) in
          match Opam_file.get_field opam "version" with
          | Some (String (_, s)) -> Some s
          | _ -> None
        in
        let name = Package.Name.of_string pkg in
        (name,
         { Package. name
         ; path = dir
         ; version_from_opam_file
         }) :: acc
      | _ -> acc)
    |> Package.Name.Map.of_list_exn
  in
  if String.Set.mem files filename then
    Some (load_dune_project ~dir packages)
  else if not (Package.Name.Map.is_empty packages) then
    Some (make_jbuilder_project ~dir packages)
  else
    None
