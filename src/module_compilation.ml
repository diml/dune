open! Stdune
open Import
open Build.O
open! No_io

module CC = Compilation_context
module SC = Super_context

(* Arguments for the compiler to prevent it from being too clever.

   The compiler creates the cmi when it thinks a .ml file has no
   corresponding .mli. However this behavior is a bit racy and doesn't
   work well when the extension is not .ml or when the .ml and .mli
   are in different directories. This flags makes the compiler think
   there is a .mli file and will the read the cmi file rather than
   create it. *)
let force_read_cmi source_file =
  [ "-intf-suffix"; Path.extension source_file ]

(* Build the cm* if the corresponding source is present, in the case of cmi if
   the mli is not present it is added as additional target to the .cmo
   generation *)
let build_cm cctx ?sandbox ?(dynlink=true) ~precompiled_cmi ~dep_graphs
      ~cm_kind (m : Module.t) =
  let sctx     = CC.super_context cctx in
  let dir      = CC.dir           cctx in
  let obj_dir  = CC.obj_dir       cctx in
  let ctx      = SC.context       sctx in
  let stdlib   = CC.stdlib        cctx in
  let vimpl    = CC.vimpl cctx in
  let mode     = Mode.of_cm_kind cm_kind in
  Context.compiler ctx mode
  |> Option.iter ~f:(fun compiler ->
    Option.iter (Module.cm_source m cm_kind) ~f:(fun src ->
      let ml_kind = Cm_kind.source cm_kind in
      let dst = Path.as_in_build_dir_exn (Module.cm_file_unsafe m cm_kind) in
      let copy_interface () =
        (* symlink the .cmi into the public interface directory *)
        if not (Module.is_private m)
        && (Obj_dir.Local.need_dedicated_public_dir obj_dir) then
          SC.add_rule sctx ~sandbox:false ~dir
            (Build.symlink
               ~src:(Module.cm_file_unsafe m Cmi)
               ~dst:(Path.as_in_build_dir_exn
                       (Module.cm_public_file_unsafe m Cmi))
            )
      in
      let extra_args, extra_deps, other_targets =
        if precompiled_cmi then
          force_read_cmi src, [], []
        else
          match cm_kind, Module.intf m
                , Vimpl.is_public_vlib_module vimpl m with
          (* If there is no mli, [ocamlY -c file.ml] produces both the
             .cmY and .cmi. We choose to use ocamlc to produce the cmi
             and to produce the cmx we have to wait to avoid race
             conditions. *)
          | Cmo, None, false ->
            copy_interface ();
            [], [], [Path.as_in_build_dir_exn (Module.cm_file_unsafe m Cmi)]
          | Cmo, None, true
          | (Cmo | Cmx), _, _ ->
            force_read_cmi src,
            [Module.cm_file_unsafe m Cmi],
            []
          | Cmi, _, _ ->
            copy_interface ();
            [], [], []
      in
      let other_targets =
        match cm_kind with
        | Cmx ->
          Path.as_in_build_dir_exn
            (Module.obj_file m ~kind:Cmx ~ext:ctx.ext_obj) :: other_targets
        | Cmi | Cmo -> other_targets
      in
      let dep_graph = Ml_kind.Dict.get dep_graphs ml_kind in
      let opaque = CC.opaque cctx in
      let other_cm_files =
        Build.dyn_paths
          (Dep_graph.deps_of dep_graph m >>^ fun deps ->
           List.concat_map deps
             ~f:(fun m ->
               let deps = [Module.cm_file_unsafe m Cmi] in
               if Module.has_impl m && cm_kind = Cmx && not opaque then
                 Module.cm_file_unsafe m Cmx :: deps
               else
                 deps))
      in
      let other_targets, cmt_args =
        match cm_kind with
        | Cmx -> (other_targets, Command.Args.S [])
        | Cmi | Cmo ->
          let fn =
            Path.as_in_build_dir_exn (Option.value_exn
                                        (Module.cmt_file m ml_kind)) in
          (fn :: other_targets, A "-bin-annot")
      in
      if CC.dir_kind cctx = Jbuild then begin
        (* Symlink the object files in the original directory for
           backward compatibility *)
        let old_dst =
          (Module.obj_name m) ^ (Cm_kind.ext cm_kind)
          |> Path.Build.relative dir
        in
        SC.add_rule sctx ~dir
          (Build.symlink ~src:(Path.build dst) ~dst:old_dst);
        List.iter other_targets ~f:(fun in_obj_dir ->
          let in_dir = Path.Build.relative dir
                         (Path.Build.basename in_obj_dir) in
          SC.add_rule sctx ~dir
            (Build.symlink ~src:(Path.build in_obj_dir) ~dst:in_dir))
      end;
      let opaque_arg =
        let intf_only = cm_kind = Cmi && not (Module.has_impl m) in
        if opaque
        || (intf_only && Ocaml_version.supports_opaque_for_mli ctx.version) then
          Command.Args.A "-opaque"
        else
          As []
      in
      let dir, no_keep_locs =
        match CC.no_keep_locs cctx
            , cm_kind
            , Ocaml_version.supports_no_keep_locs ctx.version
        with
        | true, Cmi, true ->
          (ctx.build_dir, Command.Args.As ["-no-keep-locs"])
        | true, Cmi, false ->
          (Obj_dir.Local.byte_dir obj_dir, As [])
        (* emulated -no-keep-locs *)
        | true, (Cmo | Cmx), _
        | false, _, _ ->
          (ctx.build_dir, As [])
      in
      let flags =
        let flags = Ocaml_flags.get_for_cm (CC.flags cctx) ~cm_kind in
        match Module.pp_flags m with
        | None -> flags
        | Some pp ->
          Build.fanout flags pp >>^ fun (flags, pp_flags) ->
          flags @ pp_flags
      in
      SC.add_rule sctx ?sandbox ~dir
        (Build.S.seqs [Build.paths extra_deps; other_cm_files]
           (Command.run ~dir:(Path.build dir) (Ok compiler)
              [ Command.Args.dyn flags
              ; no_keep_locs
              ; cmt_args
              ; Command.Args.S (
                  Obj_dir.Local.all_obj_dirs obj_dir ~mode
                  |> List.concat_map ~f:(fun p -> [ Command.Args.A "-I"
                                                  ; Path (Path.build p)])
                )
              ; Cm_kind.Dict.get (CC.includes cctx) cm_kind
              ; As extra_args
              ; if dynlink || cm_kind <> Cmx then As [] else A "-nodynlink"
              ; A "-no-alias-deps"; opaque_arg
              ; (match CC.alias_module cctx with
                 | None -> S []
                 | Some (m : Module.t) ->
                   As ["-open"; Module.Name.to_string (Module.name m)])
              ; As (match stdlib with
                  | None -> []
                  | Some { Dune_file.Library.Stdlib.modules_before_stdlib; _ } ->
                    let flags = ["-nopervasives"; "-nostdlib"] in
                    if Module.Name.Set.mem modules_before_stdlib
                         (Module.name m) then
                      flags
                    else
                      match CC.lib_interface_module cctx with
                      | None -> flags
                      | Some m' ->
                        (* See comment in [Dune_file.Stdlib]. *)
                        if Module.name m = Module.name m' then
                          "-w" :: "-49" :: flags
                        else
                          "-open" :: Module.Name.to_string (Module.name m')
                          :: flags)
              ; A "-o"; Target dst
              ; A "-c"; Ml_kind.flag ml_kind; Dep src
              ; Hidden_targets other_targets
              ]))))

let build_module ?sandbox ?js_of_ocaml ?dynlink ?(precompiled_cmi=false)
      ~dep_graphs cctx m =
  let build_cm cm_kind =
    build_cm cctx m ?sandbox ?dynlink ~precompiled_cmi ~dep_graphs ~cm_kind
  in
  build_cm Cmo;
  build_cm Cmx;
  if not precompiled_cmi then build_cm Cmi;
  Option.iter js_of_ocaml ~f:(fun js_of_ocaml ->
    (* Build *.cmo.js *)
    let sctx     = CC.super_context cctx in
    let dir      = CC.dir           cctx in
    let src = Path.as_in_build_dir_exn (Module.cm_file_unsafe m Cm_kind.Cmo) in
    let target = Path.Build.extend_basename src ~suffix:".js" in
    SC.add_rules sctx ~dir
      (Js_of_ocaml_rules.build_cm cctx ~js_of_ocaml ~src ~target))

let build_modules ?sandbox ?js_of_ocaml ?dynlink ?precompiled_cmi
      ~dep_graphs cctx =
  Module.Name.Map.iter
    (match CC.alias_module cctx with
     | None -> CC.modules cctx
     | Some (m : Module.t) ->
       Module.Name.Map.remove (CC.modules cctx) (Module.name m))
    ~f:(build_module cctx ?sandbox ?js_of_ocaml ?dynlink ?precompiled_cmi
          ~dep_graphs)

let ocamlc_i ?sandbox ?(flags=[]) ~dep_graphs cctx (m : Module.t) ~output =
  let sctx     = CC.super_context cctx in
  let obj_dir  = CC.obj_dir       cctx in
  let dir      = CC.dir           cctx in
  let ctx      = SC.context       sctx in
  let src = Option.value_exn (Module.file m Impl) in
  let dep_graph = Ml_kind.Dict.get dep_graphs Impl in
  let cm_deps =
    Build.dyn_paths
      (Dep_graph.deps_of dep_graph m >>^ fun deps ->
       List.concat_map deps
         ~f:(fun m -> [Module.cm_file_unsafe m Cmi]))
  in
  let ocaml_flags = Ocaml_flags.get_for_cm (CC.flags cctx) ~cm_kind:Cmo
  in
  SC.add_rule sctx ?sandbox ~dir
    (Build.S.seq cm_deps
       (Build.S.map ~f:(fun act -> Action.with_stdout_to (Path.build output) act)
          (Command.run (Ok ctx.ocamlc) ~dir:(Path.build ctx.build_dir)
             [ Command.Args.dyn ocaml_flags
             ; A "-I"; Path (Path.build (Obj_dir.Local.byte_dir obj_dir))
             ; Cm_kind.Dict.get (CC.includes cctx) Cmo
             ; (match CC.alias_module cctx with
                | None -> S []
                | Some (m : Module.t) ->
                  As ["-open"; Module.Name.to_string (Module.name m)])
             ; As flags
             ; A "-short-paths"
             ; A "-i"; Ml_kind.flag Impl; Dep src
             ]))
     >>> Build.action_dyn () ~targets:[output])
