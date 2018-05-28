(* Parsing of S-expression. The parsing is written as an automaton for which
   we provide different implementations of actions.
*)

open Base
open Stdio
open Gen_parsexp_lib.Automaton
open Gen_parsexp_lib.Automaton.Table

(* Sharing of transitions *)
module Sharing = struct
  let create_assign_id () =
    let cache = Hashtbl.Poly.create () in
    (cache,
     fun x ->
       if not (Hashtbl.mem cache x) then
         Hashtbl.add_exn cache ~key:x ~data:(Hashtbl.length cache))

  let share (table : t) =
    let transitions, assign_transition_id =
      create_assign_id ()
    in
    let transitions_eoi, assign_transition_eoi_id =
      create_assign_id ()
    in
    Array.iter table.transitions     ~f:assign_transition_id;
    Array.iter table.transitions_eoi ~f:assign_transition_eoi_id;
    (transitions, transitions_eoi)
end

let gen_code oc (t : t) =
  let (named_transitions, named_transitions_eoi) = Sharing.share t in
  let pr fmt = Out_channel.fprintf oc (Caml.(^^) fmt "\n") in
  pr "(* generated by %s *)" Caml.Sys.argv.(0);
  pr "";
  pr "open Parser_automaton_internal";
  pr "";
  pr "let raise = Parser_automaton_internal.Error.raise";
  pr "";
  let ordered_ids tbl =
    Hashtbl.fold tbl ~init:[] ~f:(fun ~key:x ~data:id acc -> (id, x) :: acc)
    |> List.sort ~compare:(fun (id1, _) (id2, _) -> compare id1 id2)
  in
  List.iter (ordered_ids named_transitions)
    ~f:(fun (id, tr) ->
      match tr with
      | Error error ->
        pr "let tr_%02d _state _char _stack =" id;
        pr "  raise _state ~at_eof:false %s" (Error.to_string error)
      | Ok { action = (eps_actions, action); goto; advance } ->
        let eps_actions =
          List.filter_map ~f:Epsilon_action.to_runtime_function eps_actions
        in
        let action = Action.to_runtime_function action in
        pr "let tr_%02d state %schar stack =" id
          (if Option.is_none action &&
              not ([%compare.equal: goto_state] goto End_block_comment) then
             "_"
           else
             "");
        List.iter eps_actions ~f:(pr "  let stack = %s state stack in");
        (match action with
         | None -> ()
         | Some s -> pr "  let stack = %s state char stack in" s);
        (match goto with
         | State n -> pr "  set_automaton_state state %d;" n
         | End_block_comment ->
           pr "  let stack = end_block_comment state char stack in";
           pr "  set_automaton_state state \
               (if block_comment_depth state <> 0 then %d else %d);"
             (State.to_int (Block_comment Normal)) (State.to_int Whitespace));
        pr "  %s state;"
          (match advance with
           | Advance     -> "advance"
           | Advance_eol -> "advance_eol");
        pr "  stack"
    );
  pr "";
  List.iter (ordered_ids named_transitions_eoi) ~f:(fun (id, tr) ->
    match tr with
    | Error error ->
      pr "let tr_eoi_%02d state _stack =" id;
      pr "  raise state ~at_eof:true %s" (Error.to_string error)
    | Ok eps_actions ->
      pr "let tr_eoi_%02d state stack =" id;
      let eps_actions =
        List.filter_map eps_actions ~f:Epsilon_action.to_runtime_function
      in
      List.iter eps_actions ~f:(pr "  let stack = %s state stack in");
      pr "  eps_eoi_check state stack");
  pr "";
  let pr_table ~per_line suffix tbl ids =
    pr "let transitions%s = function" suffix;
    for i = 0 to Array.length tbl - 1 do
      if i % per_line = 0 then begin
        if i > 0 then Out_channel.fprintf oc "\n";
        Out_channel.fprintf oc " "
      end;
      Out_channel.fprintf oc " | %02d -> tr%s_%02d" i suffix
        (Hashtbl.find_exn ids tbl.(i))
    done;
    pr "";
    pr "  | _ -> assert false"
  in
  pr_table ""     t.transitions     named_transitions     ~per_line:4;
  pr "";
  pr_table "_eoi" t.transitions_eoi named_transitions_eoi ~per_line:4

let () = gen_code Caml.stdout table
