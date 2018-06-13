{
open Stdune

let unescape s = Scanf.sscanf s "%S%!" (fun s -> s)
}

let spaces = [' ' '\t']*
let string = '"' ([^'"' '\\'] | '\\' _)* '"'
let rest_of_line = [^'\n']*
let lowercase = ['a'-'z' '_']
let idchar = ['A'-'Z' 'a'-'z' '_' '\'' '0'-'9']
let id = lowercase idchar*

rule scan acc = parse
  | eof
    { acc
    }
  | '\n'
    { Lexing.new_line lexbuf;
      scan acc lexbuf
    }
  | spaces '|' spaces (string as s) spaces "->" [^'\n']*
    { let start_line = lexbuf.lex_start_p.pos_lnum in
      let strings = collect_strings [unescape s] lexbuf in
      let stop_line = lexbuf.lex_start_p.pos_lnum in
      let sp : Sexp.String_pattern.t =
        { start_line
        ; stop_line
        ; strings = List.sort strings ~compare:String.compare
        }
      in
      scan (sp :: acc) lexbuf
    }
  | [^'\n']*
    { scan acc lexbuf
    }

and collect_strings acc = parse
  | eof
    { acc
    }
  | '\n'
    { Lexing.new_line lexbuf;
      collect_strings acc lexbuf
    }
  | spaces '|' spaces (string as s) spaces "->" [^'\n']*
    { collect_strings (unescape s :: acc) lexbuf
    }
  | spaces '|' spaces (id | '_') spaces "->" [^'\n']*
    { collect_strings acc lexbuf
    }
  | ""
    { acc
    }

{
  let pr fmt = Printf.printf (fmt ^^ "\n")

  let print i (sp : Sexp.String_pattern.t) =
    match sp.strings with
    | [] -> assert false
    | x :: l ->
      pr "  %c { start_line = %d" (if i = 0 then '[' else ';') sp.start_line;
      pr "    ; stop_line  = %d" sp.stop_line;
      pr "    ; strings    =";
      pr "        [ %S" x;
      List.iter l ~f:(pr "        ; %S");
      pr "        ]";
      pr "    }"

  let () =
    let cwd = Path.External.cwd () in
    Path.set_root cwd;
    Path.set_build_dir (Path.Kind.of_string "_build");
    let files = List.tl (Array.to_list Sys.argv) in
    List.map files ~f:(fun fn ->
      (fn, Io.with_lexbuf_from_file (Path.of_string fn) ~f:(scan [])))
    |> List.filter ~f:(fun (_, l) -> l <> [])
    |> List.iteri ~f:(fun i (fn, string_patterns) ->
      if i > 0 then pr "";
      pr "Sexp.String_pattern.register ~fname:%S" fn;
      List.iteri string_patterns ~f:print;
      pr "  ];")
}
