(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Protocol
open Alpha_context
open Client_proto_context
open Client_proto_contracts
open Client_keys_v0

let report_michelson_errors ?(no_print_source = false) ~msg
    (cctxt : #Client_context.printer) = function
  | Error errs ->
      cctxt#warning
        "%a"
        (Michelson_v1_error_reporter.report_errors
           ~details:(not no_print_source)
           ~show_source:(not no_print_source)
           ?parsed:None)
        errs
      >>= fun () ->
      cctxt#error "%s" msg >>= fun () -> Lwt.return_none
  | Ok data -> Lwt.return_some data

let group =
  {
    Tezos_clic.name = "context";
    title = "Block contextual commands (see option -block)";
  }

let alphanet = {Tezos_clic.name = "alphanet"; title = "Alphanet only commands"}

let binary_description =
  {Tezos_clic.name = "description"; title = "Binary Description"}

let commands () =
  let open Tezos_clic in
  [
    command
      ~group
      ~desc:"Access the timestamp of the block."
      (args1
         (switch ~doc:"output time in seconds" ~short:'s' ~long:"seconds" ()))
      (fixed ["get"; "timestamp"])
      (fun seconds (cctxt : Alpha_client_context.full) ->
        Shell_services.Blocks.Header.shell_header cctxt ~block:cctxt#block ()
        >>=? fun {timestamp = v; _} ->
        (if seconds then cctxt#message "%Ld" (Time.Protocol.to_seconds v)
        else cctxt#message "%s" (Time.Protocol.to_notation v))
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Lists all non empty contracts of the block."
      no_options
      (fixed ["list"; "contracts"])
      (fun () (cctxt : Alpha_client_context.full) ->
        list_contract_labels cctxt ~chain:`Main ~block:cctxt#block
        >>=? fun contracts ->
        List.iter_s
          (fun (alias, hash, kind) -> cctxt#message "%s%s%s" hash kind alias)
          contracts
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the balance of a contract."
      no_options
      (prefixes ["get"; "balance"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () (_, contract) (cctxt : Alpha_client_context.full) ->
        get_balance cctxt ~chain:`Main ~block:cctxt#block contract
        >>=? fun amount ->
        cctxt#answer "%a %s" Tez.pp amount Client_proto_args.tez_sym
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the storage of a contract."
      no_options
      (prefixes ["get"; "script"; "storage"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () (_, contract) (cctxt : Alpha_client_context.full) ->
        get_storage cctxt ~chain:`Main ~block:cctxt#block contract >>=? function
        | None -> cctxt#error "This is not a smart contract."
        | Some storage ->
            cctxt#answer "%a" Michelson_v1_printer.print_expr_unwrapped storage
            >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the code of a contract."
      no_options
      (prefixes ["get"; "script"; "code"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () (_, contract) (cctxt : Alpha_client_context.full) ->
        get_script cctxt ~chain:`Main ~block:cctxt#block contract >>=? function
        | None -> cctxt#error "This is not a smart contract."
        | Some {code; storage = _} -> (
            match Script_repr.force_decode code with
            | Error errs ->
                cctxt#error
                  "%a"
                  (Format.pp_print_list
                     ~pp_sep:Format.pp_print_newline
                     Environment.Error_monad.pp)
                  errs
            | Ok (code, _) ->
                cctxt#answer "%a" Michelson_v1_printer.print_expr_unwrapped code
                >>= fun () -> return_unit));
    command
      ~group
      ~desc:"Get the manager of a contract."
      no_options
      (prefixes ["get"; "manager"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () (_, contract) (cctxt : Alpha_client_context.full) ->
        Client_proto_contracts.get_manager
          cctxt
          ~chain:`Main
          ~block:cctxt#block
          contract
        >>=? fun manager ->
        Public_key_hash.rev_find cctxt manager >>=? fun mn ->
        Public_key_hash.to_source manager >>=? fun m ->
        cctxt#message
          "%s (%s)"
          m
          (match mn with None -> "unknown" | Some n -> "known as " ^ n)
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the delegate of a contract."
      no_options
      (prefixes ["get"; "delegate"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () (_, contract) (cctxt : Alpha_client_context.full) ->
        Client_proto_contracts.get_delegate
          cctxt
          ~chain:`Main
          ~block:cctxt#block
          contract
        >>=? function
        | None -> cctxt#message "none" >>= fun () -> return_unit
        | Some delegate ->
            Public_key_hash.rev_find cctxt delegate >>=? fun mn ->
            Public_key_hash.to_source delegate >>=? fun m ->
            cctxt#message
              "%s (%s)"
              m
              (match mn with None -> "unknown" | Some n -> "known as " ^ n)
            >>= fun () -> return_unit);
    command
      ~group:binary_description
      ~desc:"Describe unsigned block header"
      no_options
      (fixed ["describe"; "unsigned"; "block"; "header"])
      (fun () (cctxt : Alpha_client_context.full) ->
        cctxt#message
          "%a"
          Data_encoding.Binary_schema.pp
          (Data_encoding.Binary.describe
             Alpha_context.Block_header.unsigned_encoding)
        >>= fun () -> return_unit);
    command
      ~group:binary_description
      ~desc:"Describe unsigned operation"
      no_options
      (fixed ["describe"; "unsigned"; "operation"])
      (fun () (cctxt : Alpha_client_context.full) ->
        cctxt#message
          "%a"
          Data_encoding.Binary_schema.pp
          (Data_encoding.Binary.describe
             Alpha_context.Operation.unsigned_encoding)
        >>= fun () -> return_unit);
  ]
