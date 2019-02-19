open! Stdune
open Fiber.O

module type Input = Memo_intf.Input
module type Output = Memo_intf.Output
module type Decoder = Memo_intf.Decoder

module Function_name = Interned.Make(struct
    let initial_size = 1024
    let resize_policy = Interned.Greedy
    let order = Interned.Fast
  end) ()

module Function = struct
  type ('a, 'b) t =
    | Sync of ('a -> 'b)
    | Async of ('a -> 'b Fiber.t)
end

module Spec = struct
  type _ witness = ..

  type ('a, 'b) t =
    { name : Function_name.t
    ; allow_cutoff : bool
    ; input : (module Input with type t = 'a)
    ; output : (module Output with type t = 'b)
    ; decode : 'a Dune_lang.Decoder.t
    ; witness : 'a witness
    ; f : ('a, 'b) Function.t
    ; doc : string
    }

  type packed = T : (_, _) t -> packed [@@unboxed]

  let by_name = Function_name.Table.create ~default_value:None

  let register t =
    Function_name.Table.set by_name ~key:t.name ~data:(Some (T t))

  let find name =
    Function_name.Table.get by_name name
end

module Id = Id.Make()

module Run : sig
  (** Represent a run of the system *)
  type t

  (** Return the current run *)
  val current : unit -> t

  (** Whether this run is the current one *)
  val is_current : t -> bool

  (** End the current run and start a new one *)
  val restart : unit -> unit
end = struct
  type t = bool ref

  let current = ref (ref true)

  let restart () =
    !current := false;
    current := ref true

  let current () = !current
  let is_current t = !t
end

(* We can get rid of this once we use the memoization system more
   pervasively and all the dependencies are properly specified *)
module Caches = struct
  let cleaners = ref []
  let register ~clear =
    cleaners := clear :: !cleaners
  let clear () =
    List.iter !cleaners ~f:(fun f -> f ())
end

let reset () =
  Caches.clear ();
  Run.restart ()

module M = struct
  module Generic_dag = Dag

  module rec Cached_value : sig
    type 'a t =
      { data : 'a
      ; (* When was the value computed *)
        mutable calculated_at : Run.t
      ; deps : Last_dep.t list
      }
  end = Cached_value

  and State : sig
    type 'a t =
      (* [Running] includes computations that already terminated with an exception
         or cancelled because we've advanced to the next run. *)
      | Running_sync of Run.t
      | Running_async of Run.t * 'a Fiber.Ivar.t
      | Done of 'a Cached_value.t
  end = State

  and Dep_node : sig
    type ('a, 'b) t = {
      spec : ('a, 'b) Spec.t;
      input : 'a;
      id : Id.t;
      mutable dag_node : Dag.node Lazy.t;
      mutable state : 'b State.t;
    }

    type packed = T : (_, _) t -> packed [@@unboxed]
  end = Dep_node

  and Last_dep : sig
    type t = T : ('a, 'b) Dep_node.t * 'b -> t
  end = Last_dep

  and Dag : Generic_dag.S with type value := Dep_node.packed
    = Generic_dag.Make(struct type t = Dep_node.packed end)
end

module State = M.State
module Dep_node = M.Dep_node
module Last_dep = M.Last_dep
module Dag = M.Dag

module Cached_value = struct
  include M.Cached_value

  let create x ~deps =
    { deps
    ; data = x
    ; calculated_at = Run.current ()
    }

  let dep_changed (type a) (node : (_, a) Dep_node.t) prev_output curr_output =
    if node.spec.allow_cutoff then
      let (module Output : Output with type t = a) = node.spec.output in
      not (Output.equal prev_output curr_output)
    else
      true

  (* Check if a cached value is up to date. If yes, return it *)
  let rec get_async : type a. a t -> a option Fiber.t = fun t ->
    if Run.is_current t.calculated_at then
      Fiber.return (Some t.data)
    else begin
      let rec deps_changed acc = function
        | [] ->
          Fiber.parallel_map acc ~f:Fn.id >>| List.exists ~f:Fn.id
        | Last_dep.T (node, prev_output) :: deps ->
          match node.state with
          | Running_sync _ ->
            failwith "Synchronous function called [Cached_value.get_async]"
          | Running_async (run, ivar) ->
            if not (Run.is_current run) then
              Fiber.return true
            else
              let changed =
                Fiber.Ivar.read ivar >>| fun curr_output ->
                dep_changed node prev_output curr_output
              in
              deps_changed (changed :: acc) deps
          | Done t' ->
            if Run.is_current t'.calculated_at then begin
              (* handle common case separately to avoid feeding more
                 fibers to [parallel_map] *)
              if dep_changed node prev_output t'.data then
                Fiber.return true
              else
                deps_changed acc deps
            end else
              let changed =
                (match node.spec.f with
                 | Sync _ ->
                   Fiber.return (get_sync t')
                 | Async _ ->
                   get_async t') >>| function
                | None -> true
                | Some curr_output ->
                  dep_changed node prev_output curr_output
              in
              deps_changed (changed :: acc) deps
      in
      deps_changed [] t.deps >>| function
      | true -> None
      | false ->
        t.calculated_at <- Run.current ();
        Some t.data
    end
  and get_sync : type a. a t -> a option = fun t ->
    if Run.is_current t.calculated_at then
      Some t.data
    else begin
      let dep_changed = function
        | Last_dep.T (node, prev_output) ->
          match node.state with
          | Running_sync run ->
            if not (Run.is_current run)
            then
              true
            else
              failwith "dependency cycle: "
          | Running_async _ ->
            failwith
              "Synchronous function depends on an asynchronous one. That is not allowed. \
               (in fact this case should be unreachable)"
          | Done t' ->
            get_sync t' |> function
            | None -> true
            | Some curr_output ->
              dep_changed node prev_output curr_output
      in
      match List.exists ~f:dep_changed t.deps with
      | true -> None
      | false ->
        t.calculated_at <- Run.current ();
        Some t.data
    end


end

let ser_input (type a) (node : (a, _) Dep_node.t) =
  let (module Input : Input with type t = a) = node.spec.input in
  Input.to_sexp node.input

let dag_node (dep_node : _ Dep_node.t) = Lazy.force dep_node.dag_node

module Stack_frame = struct
  open Dep_node

  type t = packed

  let name (T t) = Function_name.to_string t.spec.name
  let input (T t) = ser_input t

  let equal (T a) (T b) = Id.equal a.id b.id
  let compare (T a) (T b) = Id.compare a.id b.id

  let pp ppf t =
    Format.fprintf ppf "%s %a"
      (name t)
      Sexp.pp (input t)
end

module Cycle_error = struct
  type t =
    { cycle : Stack_frame.t list
    ; stack : Stack_frame.t list
    }

  exception E of t

  let get t = t.cycle
  let stack t = t.stack
end

module type S = Memo_intf.S with type stack_frame := Stack_frame.t
module type S_sync = Memo_intf.S_sync with type stack_frame := Stack_frame.t

let global_dep_dag = Dag.create ()

(* call stack consists of two components: asynchronous call stack managed with a fiber
   context variable and synchronous call stack on top of that managed with an explicit ref *)
module Call_stack = struct

  let synchronous_call_stack = ref []

  let list_first = function
    | [] -> None
    | x :: _ -> Some x

  (* fiber context variable keys *)
  let call_stack_key = Fiber.Var.create ()
  let get_call_stack_tip () =
    match !synchronous_call_stack with
    | [] ->
      list_first (Fiber.Var.get call_stack_key |> Option.value ~default:[])
    | tip :: _ -> Some tip

  let get_call_stack () =
    let async = Fiber.Var.get call_stack_key |> Option.value ~default:[] in
    let sync = !synchronous_call_stack in
    sync @ async

  let push_async_frame frame f =
    assert (List.is_empty !synchronous_call_stack);
    let stack = get_call_stack () in
    Fiber.Var.set call_stack_key (frame :: stack) f

  let protect f ~finally = match f () with
    | res ->
      finally ();
      res
    | exception exn ->
      finally ();
      reraise exn

  let push_sync_frame frame f =
    let old = !synchronous_call_stack in
    let new_ = frame :: old in
    synchronous_call_stack := new_;
    protect f ~finally:(fun () ->
      assert ((==) !synchronous_call_stack new_);
      synchronous_call_stack := old)

end

let pp_stack ppf () =
  let stack = Call_stack.get_call_stack () in
  Format.fprintf ppf "Memoized function stack:@\n";
  Format.pp_print_list ~pp_sep:Fmt.nl
    (fun ppf t -> Format.fprintf ppf "  %a" Stack_frame.pp t)
    ppf
    stack

let dump_stack () =
  Format.eprintf "%a" pp_stack ()

module Visibility = struct
  type t =
    | Public (* available via [dune compute] *)
    | Private (* not available via [dune compute] *)
end
module type Visibility = sig
  val visibility : Visibility.t
end
module Public = struct let visibility = Visibility.Public end
module Private = struct let visibility = Visibility.Private end

let add_rev_dep dep_node =
  match Call_stack.get_call_stack_tip () with
  | None ->
    ()
  | Some (Dep_node.T rev_dep) ->
    (* if the caller doesn't already contain this as a dependent *)
    let rev_dep = dag_node rev_dep in
    try
      if Dag.is_child rev_dep dep_node |> not then
        Dag.add global_dep_dag rev_dep dep_node
    with Dag.Cycle cycle ->
      raise (Cycle_error.E {
        stack = Call_stack.get_call_stack ();
        cycle = List.map cycle ~f:(fun node -> node.Dag.data)
      })

let get_deps (node : (_, _) Dep_node.t) =
  match node with
  |  { state = Running_async _; _ } -> None
  |  { state = Running_sync _; _ } ->
    None
  |  { state = Done cv; _ } ->
    Some (List.map cv.deps ~f:(fun (Last_dep.T (n,_u)) ->
      (Function_name.to_string n.spec.name, ser_input n)))

let get_deps_from_graph_exn dep_node =
  Dag.children (dag_node dep_node)
  |> List.map ~f:(fun { Dag.data = Dep_node.T node; _ } ->
    match node.state with
    | Running_sync _ -> assert false
    | Running_async _ -> assert false
    | Done res ->
      Last_dep.T (node, res.data))

module Make_gen_sync
    (Visibility : Visibility)
    (Input : Input)
    (Decoder : Decoder with type t := Input.t)
  : S_sync with type input := Input.t = struct
  module Table = Hashtbl.Make(Input)

  type 'a t =
    { spec  : (Input.t, 'a) Spec.t
    ; cache : (Input.t, 'a) Dep_node.t Table.t
    }

  type _ Spec.witness += W : Input.t Spec.witness


  let get_deps t inp =
    match Table.find t.cache inp with
    | None -> None
    | Some node -> get_deps node

  let create name ?(allow_cutoff=true) ~doc output f =
    let name = Function_name.make name in
    let spec =
      { Spec.
        name
      ; input = (module Input)
      ; output
      ; decode = Decoder.decode
      ; allow_cutoff
      ; witness = W
      ; f = Sync f
      ; doc
      }
    in
    (match Visibility.visibility with
     | Public -> Spec.register spec
     | Private -> ());
    { cache = Table.create 1024
    ; spec
    }

  let compute t inp dep_node =
    (* define the function to update / double check intermediate result *)
    (* set context of computation then run it *)
    let res = Call_stack.push_sync_frame (T dep_node) (fun () -> match t.spec.f with
      | Sync f -> f inp
      | Async _ -> failwith "expected a synchronous function, got an asynchronous one")
    in
    (* update the output cache with the correct value *)
    let deps =
      get_deps_from_graph_exn dep_node
    in
    dep_node.state <- Done (Cached_value.create res ~deps);
    res

  (* the computation that force computes the fiber *)
  let recompute t inp (dep_node : _ Dep_node.t) =
    (* create an ivar so other threads can wait for the computation to
       finish *)
    dep_node.state <- Running_sync (Run.current ());
    compute t inp dep_node

  let exec t inp =
    match Table.find t.cache inp with
    | None ->
      let dep_node : _ Dep_node.t =
        { id = Id.gen ()
        ; input = inp
        ; spec = t.spec
        ; dag_node = lazy (assert false)
        ; state = Running_sync (Run.current ())
        }
      in
      let dag_node : Dag.node =
        { info = Dag.create_node_info global_dep_dag
        ; data = Dep_node.T dep_node
        }
      in
      dep_node.dag_node <- lazy dag_node;
      Table.add t.cache inp dep_node;
      add_rev_dep dag_node;
      compute t inp dep_node
    | Some dep_node ->
      add_rev_dep (dag_node dep_node);
      match dep_node.state with
      | Running_async _ ->
        assert false
      | Running_sync run ->
        if Run.is_current run then
          failwith "dependency cycle"
        else
          recompute t inp dep_node
      | Done cv ->
        Cached_value.get_sync cv |> function
        | Some v -> v
        | None -> recompute t inp dep_node

  let peek t inp =
    match Table.find t.cache inp with
    | None -> None
    | Some dep_node ->
      add_rev_dep (dag_node dep_node);
      match dep_node.state with
      | Running_sync _ -> failwith "dependency cycle"
      | Running_async _ -> assert false
      | Done cv ->
        if Run.is_current cv.calculated_at then
          Some cv.data
        else
          None

  let peek_exn t inp = Option.value_exn (peek t inp)

  module Stack_frame = struct
    let input (Dep_node.T dep_node) : Input.t option =
      match dep_node.spec.witness with
      | W -> Some dep_node.input
      | _ -> None

    let instance_of (Dep_node.T dep_node) ~of_ =
      dep_node.spec.name = of_.spec.name
  end
end

module Make_gen
    (Visibility : Visibility)
    (Input : Input)
    (Decoder : Decoder with type t := Input.t)
  : S with type input := Input.t = struct
  module Table = Hashtbl.Make(Input)

  type 'a t =
    { spec  : (Input.t, 'a) Spec.t
    ; cache : (Input.t, 'a) Dep_node.t Table.t
    ; mutable fdecl : (Input.t -> 'a Fiber.t) Fdecl.t option
    }

  type _ Spec.witness += W : Input.t Spec.witness

  let get_deps t inp =
    match Table.find t.cache inp with
    | None | Some { state = Running_async _; _ } -> None
    | Some { state = Running_sync _; _ } ->
      None
    | Some { state = Done cv; _ } ->
      Some (List.map cv.deps ~f:(fun (Last_dep.T (n,_u)) ->
        (Function_name.to_string n.spec.name, ser_input n)))

  let create_internal name ?(allow_cutoff=true) ~doc output f fdecl =
    let name = Function_name.make name in
    let spec =
      { Spec.
        name
      ; input = (module Input)
      ; output
      ; decode = Decoder.decode
      ; allow_cutoff
      ; witness = W
      ; f = Async f
      ; doc
      }
    in
    (match Visibility.visibility with
     | Public -> Spec.register spec
     | Private -> ());
    let cache = Table.create 1024 in
    Caches.register ~clear:(fun () -> Table.clear cache);
    { cache
    ; spec
    ; fdecl
    }

  let create name ?allow_cutoff ~doc output f =
    create_internal name ?allow_cutoff ~doc output f None

  let fcreate name ?allow_cutoff ~doc output =
    let f = Fdecl.create () in
    create_internal name ?allow_cutoff ~doc output (fun x -> Fdecl.get f x)
      (Some f)

  let set_impl t f =
    match t.fdecl with
    | None -> invalid_arg "Memo.set_impl"
    | Some fdecl -> Fdecl.set fdecl f

  let compute t inp ivar dep_node =
    (* define the function to update / double check intermediate result *)
    (* set context of computation then run it *)
    Call_stack.push_async_frame (T dep_node) (fun () -> match t.spec.f with
      | Async f -> f inp
      | Sync _ -> failwith "expected an asynchronous function, got a synchronous one"
    ) >>= fun res ->
    (* update the output cache with the correct value *)
    let deps =
      get_deps_from_graph_exn dep_node
    in
    dep_node.state <- Done (Cached_value.create res ~deps);
    (* fill the ivar for any waiting threads *)
    Fiber.Ivar.fill ivar res >>= fun () ->
    Fiber.return res

  (* the computation that force computes the fiber *)
  let recompute t inp (dep_node : _ Dep_node.t) =
    (* create an ivar so other threads can wait for the computation to
       finish *)
    let ivar : 'b Fiber.Ivar.t = Fiber.Ivar.create () in
    dep_node.state <- Running_async (Run.current (), ivar);
    compute t inp ivar dep_node

  let exec t inp =
    match Table.find t.cache inp with
    | None ->
      let ivar = Fiber.Ivar.create () in
      let dep_node : _ Dep_node.t =
        { id = Id.gen ()
        ; input = inp
        ; spec = t.spec
        ; dag_node = lazy (assert false)
        ; state = Running_async (Run.current (), ivar)
        }
      in
      let dag_node : Dag.node =
        { info = Dag.create_node_info global_dep_dag
        ; data = Dep_node.T dep_node
        }
      in
      dep_node.dag_node <- lazy dag_node;
      Table.add t.cache inp dep_node;
      add_rev_dep dag_node;
      compute t inp ivar dep_node
    | Some dep_node ->
      add_rev_dep (dag_node dep_node);
      match dep_node.state with
      | Running_sync _ -> assert false
      | Running_async (run, fut) ->
        if Run.is_current run then
          Fiber.Ivar.read fut
        else
          recompute t inp dep_node
      | Done cv ->
        Cached_value.get_async cv >>= function
        | Some v -> Fiber.return v
        | None -> recompute t inp dep_node

  let peek t inp =
    match Table.find t.cache inp with
    | None -> None
    | Some dep_node ->
      add_rev_dep (dag_node dep_node);
      match dep_node.state with
      | Running_sync _ -> assert false
      | Running_async _ -> None
      | Done cv ->
        if Run.is_current cv.calculated_at then
          Some cv.data
        else
          None

  let peek_exn t inp = Option.value_exn (peek t inp)

  module Stack_frame = struct
    let input (Dep_node.T dep_node) : Input.t option =
      match dep_node.spec.witness with
      | W -> Some dep_node.input
      | _ -> None

    let instance_of (Dep_node.T dep_node) ~of_ =
      dep_node.spec.name = of_.spec.name
  end
end

module Make(Input : Input)(Decoder : Decoder with type t := Input.t) =
  Make_gen(Public)(Input)(Decoder)

module Make_sync(Input : Input)(Decoder : Decoder with type t := Input.t) =
  Make_gen_sync(Public)(Input)(Decoder)

module Make_hidden(Input : Input) =
  Make_gen(Private)(Input)(struct
    let decode : Input.t Dune_lang.Decoder.t =
      let open Dune_lang.Decoder in
      loc >>= fun loc ->
      Exn.fatalf ~loc "<not-implemented>"
  end)

let get_func name =
  match
    let open Option.O in
    Function_name.get name >>= Spec.find
  with
  | None -> Exn.fatalf "@{<error>Error@}: function %s doesn't exist!" name
  | Some spec -> spec

let call name input =
  let (Spec.T spec) = get_func name in
  let (module Output : Output with type t = _) = spec.output in
  let input = Dune_lang.Decoder.parse spec.decode Univ_map.empty input in
  (match spec.f with
   | Async f -> f
   | Sync f -> (fun x -> Fiber.return (f x))) input >>| fun output ->
  Output.to_sexp output

module Function_info = struct
  type t =
    { name : string
    ; doc  : string
    }

  let of_spec (Spec.T spec) =
    { name = Function_name.to_string spec.name
    ; doc = spec.doc
    }
end

let registered_functions () =
  Function_name.all ()
  |> List.filter_map ~f:(Function_name.Table.get Spec.by_name)
  |> List.map ~f:Function_info.of_spec
  |> List.sort ~compare:(fun a b ->
    String.compare a.Function_info.name b.Function_info.name)

let function_info name =
  get_func name |> Function_info.of_spec

let get_call_stack = Call_stack.get_call_stack
