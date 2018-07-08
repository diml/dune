open Import

type 'a t =
  { mutable dune_version : Syntax.Version.t
  ; mutable used         : ('a * Loc.t list) Module.Name.Map.t
  }

let create () =
  { dune_version = (max_int, max_int)
  ; used = Module.Name.Map.empty
  }

let acknowledge t part ~loc ~modules ~dune_version =
  t.dune_version <- min t.dune_version dune_version;
  t.used <-
    Module.Name.Map.merge modules t.used ~f:(fun _name x y ->
      match x with
      | None -> y
      | Some _ ->
        Some (part,
              loc :: match y with
              | None -> []
              | Some (_, l) -> l))

let find t name = Option.map (Module.Name.Map.find t.used name) ~f:fst

let emit_errors t =
  Module.Name.Map.iteri t.used ~f:(fun name (_, locs) ->
    match locs with
    | [] | [_] -> ()
    | loc :: _ ->
      let loc = Loc.in_file loc.start.pos_fname in
      match Stanza.File_kind.of_syntax t.dune_version with
      | Jbuild ->
        Loc.warn loc
          "Module %a is used in several stanzas:@\n\
           @[<v>%a@]@\n\
           @[%a@]@\n\
           This warning will become an error in the future."
          Module.Name.pp_quote name
          (Fmt.list (Fmt.prefix (Fmt.string "- ") Loc.pp_file_colon_line))
          locs
          Format.pp_print_text
          "To remove this warning, you must specify an explicit \"modules\" \
           field in every library, executable, and executables stanzas in \
           this jbuild file. Note that each module cannot appear in more \
           than one \"modules\" field - it must belong to a single library \
           or executable."
      | Dune ->
        Loc.fail loc
          "Module %a is used in several stanzas:@\n\
           @[<v>%a@]@\n\
           @[%a@]"
          Module.Name.pp_quote name
          (Fmt.list (Fmt.prefix (Fmt.string "- ") Loc.pp_file_colon_line))
          locs
          Format.pp_print_text
          "To fix this error, you must specify an explicit \"modules\" \
           field in every library, executable, and executables stanzas in \
           this dune file. Note that each module cannot appear in more \
           than one \"modules\" field - it must belong to a single library \
           or executable.")
