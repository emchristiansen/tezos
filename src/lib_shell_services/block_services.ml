(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2021 Nomadic Labs. <contact@nomadic-labs.com>          *)
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

open Data_encoding
module Proof = Tezos_context_sigs.Context.Proof_types

(* TODO: V2.Tree32 has been chosen arbitrarily ; maybe it's not the best option *)
module Merkle_proof_encoding =
  Tezos_context_merkle_proof_encoding.Merkle_proof_encoding.V2.Tree32

type chain = [`Main | `Test | `Hash of Chain_id.t]

let metadata_rpc_arg =
  let construct = function `Always -> "always" | `Never -> "never" in
  let destruct arg =
    Result.catch_f
      (fun () ->
        match arg with
        | "always" -> `Always
        | "never" -> `Never
        | s -> invalid_arg (Format.sprintf "unrecognize parameter %s" s))
      (fun exn ->
        Format.sprintf "Invalid argument: %s" (Printexc.to_string exn))
  in
  let description = "defines the way metadata are queried" in
  let name = "metadata_rpc_arg" in
  Tezos_rpc.Arg.make ~descr:description ~name ~construct ~destruct ()

let parse_chain s =
  try
    match s with
    | "main" -> Ok `Main
    | "test" -> Ok `Test
    | h -> Ok (`Hash (Chain_id.of_b58check_exn h))
  with _ -> Error "Cannot parse chain identifier."

let chain_to_string = function
  | `Main -> "main"
  | `Test -> "test"
  | `Hash h -> Chain_id.to_b58check h

let chain_arg =
  let name = "chain_id" in
  let descr =
    "A chain identifier. This is either a chain hash in Base58Check notation \
     or a one the predefined aliases: 'main', 'test'."
  in
  let construct = chain_to_string in
  let destruct = parse_chain in
  Tezos_rpc.Arg.make ~name ~descr ~construct ~destruct ()

type block =
  [ `Genesis
  | `Head of int
  | `Alias of [`Caboose | `Checkpoint | `Savepoint] * int
  | `Hash of Block_hash.t * int
  | `Level of Int32.t ]

let parse_block s =
  let delims = ['~'; '-'; '+'] in
  let count_delims s =
    List.map
      (fun d ->
        (String.fold_left (fun i c -> if c = d then i + 1 else i) 0 s, d))
      delims
  in
  let split_on_delim counts =
    match List.fold_left (fun i (v, _) -> i + v) 0 counts with
    | 0 -> ([s], ' ')
    | 1 ->
        let delim =
          WithExceptions.Option.get ~loc:__LOC__
          @@ List.assoc ~equal:Int.equal 1 counts
        in
        (String.split_no_empty delim s, delim)
    | _ -> raise Exit
  in
  (* Converts a string representing a block level into a Int32. Fails
     if the resulting integer is negative. *)
  let to_valid_level_id s =
    let l = Int32.of_string s in
    if Compare.Int32.(l < 0l) then raise Exit else l
  in
  (* Converts an Int32 into a level identifier. If [?offset] is given,
     returns the level identifier minus that offset. *)
  let to_level ?offset l =
    if Compare.Int32.(l = 0l) then Ok `Genesis
    else
      match offset with
      | Some ofs -> Ok (`Level Int32.(sub l ofs))
      | None -> Ok (`Level l)
  in
  try
    match split_on_delim (count_delims s) with
    | ["genesis"], _ -> Ok `Genesis
    | ["genesis"; n], '+' -> Ok (`Level (Int32.of_string n))
    | ["head"], _ -> Ok (`Head 0)
    | ["head"; n], '~' | ["head"; n], '-' -> Ok (`Head (int_of_string n))
    | ["checkpoint"], _ -> Ok (`Alias (`Checkpoint, 0))
    | ["checkpoint"; n], '~' | ["checkpoint"; n], '-' ->
        Ok (`Alias (`Checkpoint, int_of_string n))
    | ["checkpoint"; n], '+' -> Ok (`Alias (`Checkpoint, -int_of_string n))
    | ["savepoint"], _ -> Ok (`Alias (`Savepoint, 0))
    | ["savepoint"; n], '~' | ["savepoint"; n], '-' ->
        Ok (`Alias (`Savepoint, int_of_string n))
    | ["savepoint"; n], '+' -> Ok (`Alias (`Savepoint, -int_of_string n))
    | ["caboose"], _ -> Ok (`Alias (`Caboose, 0))
    | ["caboose"; n], '~' | ["caboose"; n], '-' ->
        Ok (`Alias (`Caboose, int_of_string n))
    | ["caboose"; n], '+' -> Ok (`Alias (`Caboose, -int_of_string n))
    | [hol], _ -> (
        match Block_hash.of_b58check_opt hol with
        | Some h -> Ok (`Hash (h, 0))
        | None -> to_level (to_valid_level_id s))
    | [hol; n], '~' | [hol; n], '-' -> (
        match Block_hash.of_b58check_opt hol with
        | Some h -> Ok (`Hash (h, int_of_string n))
        | None ->
            let offset = to_valid_level_id n in
            to_level ~offset (to_valid_level_id hol))
    | [hol; n], '+' -> (
        match Block_hash.of_b58check_opt hol with
        | Some h -> Ok (`Hash (h, -int_of_string n))
        | None ->
            let offset = Int32.neg (to_valid_level_id n) in
            to_level ~offset (to_valid_level_id hol))
    | _ -> raise Exit
  with _ -> Error ("Cannot parse block identifier: " ^ s)

type range = [`Level of Int32.t] * [`Level of Int32.t]

let parse_block_range r =
  try
    match String.split '.' r with
    | [starts; ""; ends] ->
        let to_level s =
          let l = Int32.of_string s in
          if Compare.Int32.(l < 0l) then raise Exit ;
          `Level l
        in
        Ok (to_level starts, to_level ends)
    | _ -> raise Exit
  with _ ->
    Error
      (Format.asprintf
         "Cannot parse block range: %S (expected <level>..<level>)"
         r)

type block_or_range = Block of block | Range of range

let parse_block_or_range r =
  if String.contains r '.' then
    Result.map (fun r -> Range r) (parse_block_range r)
  else Result.map (fun b -> Block b) (parse_block r)

let alias_to_string = function
  | `Checkpoint -> "checkpoint"
  | `Savepoint -> "savepoint"
  | `Caboose -> "caboose"

let to_string = function
  | `Genesis -> "genesis"
  | `Alias (a, 0) -> alias_to_string a
  | `Alias (a, n) when n < 0 -> Printf.sprintf "%s+%d" (alias_to_string a) (-n)
  | `Alias (a, n) -> Printf.sprintf "%s~%d" (alias_to_string a) n
  | `Head 0 -> "head"
  | `Head n when n < 0 -> Printf.sprintf "head+%d" (-n)
  | `Head n -> Printf.sprintf "head~%d" n
  | `Hash (h, 0) -> Block_hash.to_b58check h
  | `Hash (h, n) when n < 0 ->
      Printf.sprintf "%s+%d" (Block_hash.to_b58check h) (-n)
  | `Hash (h, n) -> Printf.sprintf "%s~%d" (Block_hash.to_b58check h) n
  | `Level i -> Printf.sprintf "%d" (Int32.to_int i)

let blocks_arg =
  let name = "block_id" in
  let descr =
    "A block identifier. This is either a block hash in Base58Check notation, \
     one the predefined aliases: 'genesis', 'head' or a block level (index in \
     the chain). One might also use 'head~N' or '<hash>~N' where N is an \
     integer to denote the Nth predecessor of the designated block.Also, \
     '<hash>+N' denotes the Nth successor of a block."
  in
  let construct = to_string in
  let destruct = parse_block in
  Tezos_rpc.Arg.make ~name ~descr ~construct ~destruct ()

type chain_prefix = unit * chain

type prefix = chain_prefix * block

let chain_path = Tezos_rpc.Path.(root / "chains" /: chain_arg)

let mempool_path p = Tezos_rpc.Path.(p / "mempool")

let live_blocks_path p = Tezos_rpc.Path.(p / "live_blocks")

let dir_path : (chain_prefix, chain_prefix) Tezos_rpc.Path.t =
  Tezos_rpc.Path.(open_root / "blocks")

let path = Tezos_rpc.Path.(dir_path /: blocks_arg)

type operation_list_quota = {max_size : int; max_op : int option}

let operation_list_quota_encoding =
  conv
    (fun {max_size; max_op} -> (max_size, max_op))
    (fun (max_size, max_op) -> {max_size; max_op})
    (obj2 (req "max_size" int31) (opt "max_op" int31))

let raw_context_encoding =
  let open Proof in
  mu "raw_context" (fun encoding ->
      union
        [
          case
            (Tag 0)
            bytes
            ~title:"Key"
            (function Key k -> Some k | _ -> None)
            (fun k -> Key k);
          case
            (Tag 1)
            (assoc encoding)
            ~title:"Dir"
            (function Dir map -> Some (String.Map.bindings map) | _ -> None)
            (fun bindings ->
              Dir
                (List.fold_left
                   (fun wip_map (k, v) -> String.Map.add k v wip_map)
                   String.Map.empty
                   bindings));
          case
            (Tag 2)
            null
            ~title:"Cut"
            (function Cut -> Some () | _ -> None)
            (fun () -> Cut);
        ])

let raw_context_insert =
  let open Proof in
  let default = Dir String.Map.empty in
  (* not tail recursive but over the length of [k], which is small *)
  let rec aux (k, v) ctx =
    let d = match ctx with Dir d -> d | Key _ | Cut -> String.Map.empty in
    match k with
    | [] -> v
    | [kh] -> Dir (String.Map.add kh v d)
    | kh :: ktl ->
        Dir
          (String.Map.update
             kh
             (fun ctxtopt ->
               let ctx' = Option.value ctxtopt ~default in
               Some (aux (ktl, v) ctx'))
             d)
  in
  aux

let stringmap_encoding value_encoding =
  let open Data_encoding in
  conv
    String.Map.bindings
    (fun l ->
      List.fold_left
        (fun acc (k, v) -> String.Map.add k v acc)
        String.Map.empty
        l)
    (list (tup2 string value_encoding))

let merkle_tree_encoding : Proof.merkle_tree Data_encoding.t =
  let open Proof in
  let open Data_encoding in
  let hash_tag = 0 and hash_encoding = tup2 bool string in
  let data_tag = 1 and data_encoding = raw_context_encoding in
  let continue_tag = 2 in
  mu "merkle_tree" (fun encoding ->
      let continue_encoding = encoding in
      stringmap_encoding
        (matching
           (function
             | Hash (kind, content) ->
                 matched
                   hash_tag
                   hash_encoding
                   ( (match kind with Contents -> true | Node -> false),
                     content )
             | Data raw_context -> matched data_tag data_encoding raw_context
             | Continue dir -> matched continue_tag encoding dir)
           [
             case
               (Tag hash_tag)
               ~title:"Hash"
               hash_encoding
               (function Hash (k, h) -> Some (k = Contents, h) | _ -> None)
               (fun (k, h) ->
                 let kind = if k then Contents else Node in
                 Hash (kind, h));
             case
               (Tag data_tag)
               data_encoding
               ~title:"Data"
               (function Data raw_context -> Some raw_context | _ -> None)
               (fun raw_context -> Data raw_context);
             case
               (Tag continue_tag)
               continue_encoding
               ~title:"Continue"
               (function Continue dir -> Some dir | _ -> None)
               (fun dir -> Continue dir);
           ]))

module type PROTO = sig
  val hash : Protocol_hash.t

  type block_header_data

  val block_header_data_encoding : block_header_data Data_encoding.t

  type block_header_metadata

  val block_header_metadata_encoding : block_header_metadata Data_encoding.t

  type operation_data

  type operation_receipt

  type operation = {
    shell : Operation.shell_header;
    protocol_data : operation_data;
  }

  val operation_data_encoding : operation_data Data_encoding.t

  val operation_receipt_encoding : operation_receipt Data_encoding.t

  val operation_data_and_receipt_encoding :
    (operation_data * operation_receipt) Data_encoding.t
end

type protocols = {
  current_protocol : Protocol_hash.t;
  next_protocol : Protocol_hash.t;
}

let raw_protocol_encoding =
  conv
    (fun {current_protocol; next_protocol} -> (current_protocol, next_protocol))
    (fun (current_protocol, next_protocol) -> {current_protocol; next_protocol})
    (obj2
       (req "protocol" Protocol_hash.encoding)
       (req "next_protocol" Protocol_hash.encoding))

module Make (Proto : PROTO) (Next_proto : PROTO) = struct
  let protocol_hash = Protocol_hash.to_b58check Proto.hash

  let next_protocol_hash = Protocol_hash.to_b58check Next_proto.hash

  type raw_block_header = {
    shell : Block_header.shell_header;
    protocol_data : Proto.block_header_data;
  }

  let raw_block_header_encoding =
    def "raw_block_header"
    @@ conv
         (fun {shell; protocol_data} -> (shell, protocol_data))
         (fun (shell, protocol_data) -> {shell; protocol_data})
         (merge_objs
            Block_header.shell_header_encoding
            Proto.block_header_data_encoding)

  type block_header = {
    chain_id : Chain_id.t;
    hash : Block_hash.t;
    shell : Block_header.shell_header;
    protocol_data : Proto.block_header_data;
  }

  let block_header_encoding =
    def "block_header"
    @@ conv
         (fun {chain_id; hash; shell; protocol_data} ->
           (((), chain_id, hash), {shell; protocol_data}))
         (fun (((), chain_id, hash), {shell; protocol_data}) ->
           {chain_id; hash; shell; protocol_data})
         (merge_objs
            (obj3
               (req "protocol" (constant protocol_hash))
               (req "chain_id" Chain_id.encoding)
               (req "hash" Block_hash.encoding))
            raw_block_header_encoding)

  type block_metadata = {
    protocol_data : Proto.block_header_metadata;
    test_chain_status : Test_chain_status.t;
    (* for the next block: *)
    max_operations_ttl : int;
    max_operation_data_length : int;
    max_block_header_length : int;
    operation_list_quota : operation_list_quota list;
  }

  let block_metadata_encoding =
    def "block_header_metadata"
    @@ conv
         (fun {
                protocol_data;
                test_chain_status;
                max_operations_ttl;
                max_operation_data_length;
                max_block_header_length;
                operation_list_quota;
              } ->
           ( ( (),
               (),
               test_chain_status,
               max_operations_ttl,
               max_operation_data_length,
               max_block_header_length,
               operation_list_quota ),
             protocol_data ))
         (fun ( ( (),
                  (),
                  test_chain_status,
                  max_operations_ttl,
                  max_operation_data_length,
                  max_block_header_length,
                  operation_list_quota ),
                protocol_data ) ->
           {
             protocol_data;
             test_chain_status;
             max_operations_ttl;
             max_operation_data_length;
             max_block_header_length;
             operation_list_quota;
           })
         (merge_objs
            (obj7
               (req "protocol" (constant protocol_hash))
               (req "next_protocol" (constant next_protocol_hash))
               (req "test_chain_status" Test_chain_status.encoding)
               (req "max_operations_ttl" int31)
               (req "max_operation_data_length" int31)
               (req "max_block_header_length" int31)
               (req
                  "max_operation_list_length"
                  (dynamic_size (list operation_list_quota_encoding))))
            Proto.block_header_metadata_encoding)

  let next_operation_encoding =
    let open Data_encoding in
    def "next_operation"
    @@ conv
         (fun Next_proto.{shell; protocol_data} -> ((), (shell, protocol_data)))
         (fun ((), (shell, protocol_data)) -> {shell; protocol_data})
         (merge_objs
            (obj1 (req "protocol" (constant next_protocol_hash)))
            (merge_objs
               (dynamic_size Operation.shell_header_encoding)
               (dynamic_size Next_proto.operation_data_encoding)))

  type operation_receipt =
    | Empty
    | Too_large
    | Receipt of Proto.operation_receipt

  type operation = {
    chain_id : Chain_id.t;
    hash : Operation_hash.t;
    shell : Operation.shell_header;
    protocol_data : Proto.operation_data;
    receipt : operation_receipt;
  }

  let operation_data_encoding =
    let open Data_encoding in
    union
      ~tag_size:`Uint8
      [
        case
          ~title:"Operation with too large metadata"
          (Tag 0)
          (merge_objs
             Proto.operation_data_encoding
             (obj1 (req "metadata" (constant "too large"))))
          (function
            | operation_data, Too_large -> Some (operation_data, ()) | _ -> None)
          (fun (operation_data, ()) -> (operation_data, Too_large));
        case
          ~title:"Operation without metadata"
          (Tag 1)
          Proto.operation_data_encoding
          (function operation_data, Empty -> Some operation_data | _ -> None)
          (fun operation_data -> (operation_data, Empty));
        case
          ~title:"Operation with metadata"
          (Tag 2)
          Proto.operation_data_and_receipt_encoding
          (function
            | operation_data, Receipt receipt -> Some (operation_data, receipt)
            | _ -> None)
          (function
            | operation_data, receipt -> (operation_data, Receipt receipt));
      ]

  let operation_encoding =
    def "operation"
    @@
    let open Data_encoding in
    conv
      (fun {chain_id; hash; shell; protocol_data; receipt} ->
        (((), chain_id, hash), (shell, (protocol_data, receipt))))
      (fun (((), chain_id, hash), (shell, (protocol_data, receipt))) ->
        {chain_id; hash; shell; protocol_data; receipt})
      (merge_objs
         (obj3
            (req "protocol" (constant protocol_hash))
            (req "chain_id" Chain_id.encoding)
            (req "hash" Operation_hash.encoding))
         (merge_objs
            (dynamic_size Operation.shell_header_encoding)
            (dynamic_size operation_data_encoding)))

  type block_info = {
    chain_id : Chain_id.t;
    hash : Block_hash.t;
    header : raw_block_header;
    metadata : block_metadata option;
    operations : operation list list;
  }

  let block_info_encoding =
    conv
      (fun {chain_id; hash; header; metadata; operations} ->
        ((), chain_id, hash, header, metadata, operations))
      (fun ((), chain_id, hash, header, metadata, operations) ->
        {chain_id; hash; header; metadata; operations})
      (obj6
         (req "protocol" (constant protocol_hash))
         (req "chain_id" Chain_id.encoding)
         (req "hash" Block_hash.encoding)
         (req "header" (dynamic_size raw_block_header_encoding))
         (opt "metadata" (dynamic_size block_metadata_encoding))
         (req "operations" (list (dynamic_size (list operation_encoding)))))

  module S = struct
    let path : prefix Tezos_rpc.Path.context = Tezos_rpc.Path.open_root

    let hash =
      Tezos_rpc.Service.get_service
        ~description:"The block's hash, its unique identifier."
        ~query:Tezos_rpc.Query.empty
        ~output:Block_hash.encoding
        Tezos_rpc.Path.(path / "hash")

    let header =
      Tezos_rpc.Service.get_service
        ~description:"The whole block header."
        ~query:Tezos_rpc.Query.empty
        ~output:block_header_encoding
        Tezos_rpc.Path.(path / "header")

    let raw_header =
      Tezos_rpc.Service.get_service
        ~description:"The whole block header (unparsed)."
        ~query:Tezos_rpc.Query.empty
        ~output:bytes
        Tezos_rpc.Path.(path / "header" / "raw")

    let metadata =
      Tezos_rpc.Service.get_service
        ~description:"All the metadata associated to the block."
        ~query:Tezos_rpc.Query.empty
        ~output:block_metadata_encoding
        Tezos_rpc.Path.(path / "metadata")

    let metadata_hash =
      Tezos_rpc.Service.get_service
        ~description:
          "Hash of the metadata associated to the block. This is only set on \
           blocks starting from environment V1."
        ~query:Tezos_rpc.Query.empty
        ~output:Block_metadata_hash.encoding
        Tezos_rpc.Path.(path / "metadata_hash")

    let protocols =
      Tezos_rpc.Service.get_service
        ~description:"Current and next protocol."
        ~query:Tezos_rpc.Query.empty
        ~output:raw_protocol_encoding
        Tezos_rpc.Path.(path / "protocols")

    let resulting_context_hash =
      Tezos_rpc.Service.get_service
        ~description:"Context hash resulting of the block application."
        ~query:Tezos_rpc.Query.empty
        ~output:Context_hash.encoding
        Tezos_rpc.Path.(path / "resulting_context_hash")

    module Header = struct
      let path = Tezos_rpc.Path.(path / "header")

      let shell_header =
        Tezos_rpc.Service.get_service
          ~description:"The shell-specific fragment of the block header."
          ~query:Tezos_rpc.Query.empty
          ~output:Block_header.shell_header_encoding
          Tezos_rpc.Path.(path / "shell")

      let protocol_data =
        Tezos_rpc.Service.get_service
          ~description:"The version-specific fragment of the block header."
          ~query:Tezos_rpc.Query.empty
          ~output:
            (conv
               (fun h -> ((), h))
               (fun ((), h) -> h)
               (merge_objs
                  (obj1 (req "protocol" (constant protocol_hash)))
                  Proto.block_header_data_encoding))
          Tezos_rpc.Path.(path / "protocol_data")

      let raw_protocol_data =
        Tezos_rpc.Service.get_service
          ~description:
            "The version-specific fragment of the block header (unparsed)."
          ~query:Tezos_rpc.Query.empty
          ~output:bytes
          Tezos_rpc.Path.(path / "protocol_data" / "raw")
    end

    let force_operation_metadata_query =
      let open Tezos_rpc.Query in
      query (fun force_metadata metadata ->
          object
            method force_metadata = force_metadata

            method metadata = metadata
          end)
      |+ flag
           "force_metadata"
           ~descr:
             "DEPRECATED: Forces to recompute the operations metadata if it \
              was considered as too large."
           (fun x -> x#force_metadata)
      |+ opt_field
           "metadata"
           ~descr:
             "Specifies whether or not if the operations metadata should be \
              returned. To get the metadata, even if it is needed to recompute \
              them, use \"always\". To avoid getting the metadata, use \
              \"never\". By default, the metadata will be returned depending \
              on the node's metadata size limit policy."
           metadata_rpc_arg
           (fun x -> x#metadata)
      |> seal

    module Operations = struct
      let path = Tezos_rpc.Path.(path / "operations")

      let operations =
        Tezos_rpc.Service.get_service
          ~description:"All the operations included in the block."
          ~query:force_operation_metadata_query
          ~output:(list (dynamic_size (list operation_encoding)))
          path

      let list_arg =
        let name = "list_offset" in
        let descr = "Index `n` of the requested validation pass." in
        let construct = string_of_int in
        let destruct s =
          try Ok (int_of_string s)
          with _ -> Error (Format.sprintf "Invalid list offset (%s)" s)
        in
        Tezos_rpc.Arg.make ~name ~descr ~construct ~destruct ()

      let offset_arg =
        let name = "operation_offset" in
        let descr =
          "Index `m` of the requested operation in its validation pass."
        in
        let construct = string_of_int in
        let destruct s =
          try Ok (int_of_string s)
          with _ -> Error (Format.sprintf "Invalid operation offset (%s)" s)
        in
        Tezos_rpc.Arg.make ~name ~descr ~construct ~destruct ()

      let operations_in_pass =
        Tezos_rpc.Service.get_service
          ~description:
            "All the operations included in `n-th` validation pass of the \
             block."
          ~query:force_operation_metadata_query
          ~output:(list operation_encoding)
          Tezos_rpc.Path.(path /: list_arg)

      let operation =
        Tezos_rpc.Service.get_service
          ~description:
            "The `m-th` operation in the `n-th` validation pass of the block."
          ~query:force_operation_metadata_query
          ~output:operation_encoding
          Tezos_rpc.Path.(path /: list_arg /: offset_arg)
    end

    module Operation_hashes = struct
      let path = Tezos_rpc.Path.(path / "operation_hashes")

      let operation_hashes =
        Tezos_rpc.Service.get_service
          ~description:"The hashes of all the operations included in the block."
          ~query:Tezos_rpc.Query.empty
          ~output:(list (list Operation_hash.encoding))
          path

      let operation_hashes_in_pass =
        Tezos_rpc.Service.get_service
          ~description:
            "All the operations included in `n-th` validation pass of the \
             block."
          ~query:Tezos_rpc.Query.empty
          ~output:(list Operation_hash.encoding)
          Tezos_rpc.Path.(path /: Operations.list_arg)

      let operation_hash =
        Tezos_rpc.Service.get_service
          ~description:
            "The hash of then `m-th` operation in the `n-th` validation pass \
             of the block."
          ~query:Tezos_rpc.Query.empty
          ~output:Operation_hash.encoding
          Tezos_rpc.Path.(path /: Operations.list_arg /: Operations.offset_arg)
    end

    module Operation_metadata_hashes = struct
      let root =
        Tezos_rpc.Service.get_service
          ~description:
            "The root hash of the operations metadata from the block. This is \
             only set on blocks starting from environment V1."
          ~query:Tezos_rpc.Query.empty
          ~output:Operation_metadata_list_list_hash.encoding
          Tezos_rpc.Path.(path / "operations_metadata_hash")

      let path = Tezos_rpc.Path.(path / "operation_metadata_hashes")

      let operation_metadata_hashes =
        Tezos_rpc.Service.get_service
          ~description:
            "The hashes of all the operation metadata included in the block. \
             This is only set on blocks starting from environment V1."
          ~query:Tezos_rpc.Query.empty
          ~output:(list (list Operation_metadata_hash.encoding))
          path

      let operation_metadata_hashes_in_pass =
        Tezos_rpc.Service.get_service
          ~description:
            "All the operation metadata included in `n-th` validation pass of \
             the block. This is only set on blocks starting from environment \
             V1."
          ~query:Tezos_rpc.Query.empty
          ~output:(list Operation_metadata_hash.encoding)
          Tezos_rpc.Path.(path /: Operations.list_arg)

      let operation_metadata_hash =
        Tezos_rpc.Service.get_service
          ~description:
            "The hash of then `m-th` operation metadata in the `n-th` \
             validation pass of the block. This is only set on blocks starting \
             from environment V1."
          ~query:Tezos_rpc.Query.empty
          ~output:Operation_metadata_hash.encoding
          Tezos_rpc.Path.(path /: Operations.list_arg /: Operations.offset_arg)
    end

    module Helpers = struct
      let path = Tezos_rpc.Path.(path / "helpers")

      module Forge = struct
        let block_header =
          Tezos_rpc.Service.post_service
            ~description:"Forge a block header"
            ~query:Tezos_rpc.Query.empty
            ~input:Block_header.encoding
            ~output:(obj1 (req "block" bytes))
            Tezos_rpc.Path.(path / "forge_block_header")
      end

      module Preapply = struct
        let path = Tezos_rpc.Path.(path / "preapply")

        let block_result_encoding =
          obj2
            (req "shell_header" Block_header.shell_header_encoding)
            (req
               "operations"
               (list (Preapply_result.encoding Tezos_rpc.Error.encoding)))

        type block_param = {
          protocol_data : Next_proto.block_header_data;
          operations : Next_proto.operation list list;
        }

        let block_param_encoding =
          conv
            (fun {protocol_data; operations} -> (protocol_data, operations))
            (fun (protocol_data, operations) -> {protocol_data; operations})
            (obj2
               (req
                  "protocol_data"
                  (conv
                     (fun h -> ((), h))
                     (fun ((), h) -> h)
                     (merge_objs
                        (obj1 (req "protocol" (constant next_protocol_hash)))
                        (dynamic_size Next_proto.block_header_data_encoding))))
               (req
                  "operations"
                  (list (dynamic_size (list next_operation_encoding)))))

        let block_query =
          let open Tezos_rpc.Query in
          query (fun sort timestamp ->
              object
                method sort_operations = sort

                method timestamp = timestamp
              end)
          |+ flag "sort" (fun t -> t#sort_operations)
          |+ opt_field "timestamp" Time.Protocol.rpc_arg (fun t -> t#timestamp)
          |> seal

        let block =
          Tezos_rpc.Service.post_service
            ~description:
              "Simulate the validation of a block that would contain the given \
               operations and return the resulting fitness and context hash."
            ~query:block_query
            ~input:block_param_encoding
            ~output:block_result_encoding
            Tezos_rpc.Path.(path / "block")

        let operations =
          Tezos_rpc.Service.post_service
            ~description:
              "Simulate the application of the operations with the context of \
               the given block and return the result of each operation \
               application."
            ~query:Tezos_rpc.Query.empty
            ~input:(list next_operation_encoding)
            ~output:
              (list
                 (dynamic_size Next_proto.operation_data_and_receipt_encoding))
            Tezos_rpc.Path.(path / "operations")
      end

      let complete =
        let prefix_arg =
          let destruct s = Ok s and construct s = s in
          Tezos_rpc.Arg.make ~name:"prefix" ~destruct ~construct ()
        in
        Tezos_rpc.Service.get_service
          ~description:
            "Try to complete a prefix of a Base58Check-encoded data. This RPC \
             is actually able to complete hashes of block, operations, \
             public_keys and contracts."
          ~query:Tezos_rpc.Query.empty
          ~output:(list string)
          Tezos_rpc.Path.(path / "complete" /: prefix_arg)
    end

    module Context = struct
      let path = Tezos_rpc.Path.(path / "context")

      let raw_bytes_path = Tezos_rpc.Path.(path / "raw" / "bytes")

      let merkle_tree_v1_path = Tezos_rpc.Path.(path / "merkle_tree")

      (* The duplication of the ["/merkle_tree"] RPC path is due to MR !5535.
         This MR introduces a breaking change in the former [merkle_tree] RPC,
         because it changes the data type it returns.
         In order to avoid breaking clients that still use the old code,
         we keep the old RPC at path ["/merkle_tree"], and introduce the new one
         at path ["/merkle_tree_v2"].
         Once we are sure that all clients have migrated to the new code, we will
         1) duplicate the behaviour of ["/merkle_tree_v2"] onto ["/merkle_tree"],
            and make the clients call ["/merkle_tree"],
         2) once all clients have applied patch 1), remove ["/merkle_tree_v2"]
            altogether. *)
      let merkle_tree_v2_path = Tezos_rpc.Path.(path / "merkle_tree_v2")

      let context_path_arg : string Tezos_rpc.Arg.t =
        let name = "context_path" in
        let descr = "A path inside the context" in
        let construct s = s in
        let destruct s = Ok s in
        Tezos_rpc.Arg.make ~name ~descr ~construct ~destruct ()

      let raw_context_query : < depth : int option > Tezos_rpc.Query.t =
        let open Tezos_rpc.Query in
        query (fun depth ->
            object
              method depth = depth
            end)
        |+ opt_field "depth" Tezos_rpc.Arg.uint (fun t -> t#depth)
        |> seal

      let read =
        Tezos_rpc.Service.get_service
          ~description:"Returns the raw context."
          ~query:raw_context_query
          ~output:raw_context_encoding
          Tezos_rpc.Path.(raw_bytes_path /:* context_path_arg)

      let merkle_tree_query : < holey : bool option > Tezos_rpc.Query.t =
        let open Tezos_rpc.Query in
        query (fun holey ->
            object
              method holey = holey
            end)
        |+ opt_field
             ~descr:"Send only hashes, omit data of key"
             "holey"
             Tezos_rpc.Arg.bool
             (fun t -> t#holey)
        |> seal

      let merkle_tree =
        Tezos_rpc.Service.get_service
          ~description:"Returns the merkle tree of a piece of context."
          ~query:merkle_tree_query
          ~output:(option merkle_tree_encoding)
          Tezos_rpc.Path.(merkle_tree_v1_path /:* context_path_arg)

      let merkle_tree_v2 =
        Tezos_rpc.Service.get_service
          ~description:"Returns the Irmin merkle tree of a piece of context."
          ~query:merkle_tree_query
          ~output:(option Merkle_proof_encoding.tree_proof_encoding)
          Tezos_rpc.Path.(merkle_tree_v2_path /:* context_path_arg)
    end

    let info =
      Tezos_rpc.Service.get_service
        ~description:
          "All the information about a block. The associated metadata may not \
           be present depending on the history mode and block's distance from \
           the head."
        ~query:force_operation_metadata_query
        ~output:block_info_encoding
        path

    module Mempool = struct
      type t = {
        applied : (Operation_hash.t * Next_proto.operation) list;
        refused : (Next_proto.operation * error list) Operation_hash.Map.t;
        outdated : (Next_proto.operation * error list) Operation_hash.Map.t;
        branch_refused :
          (Next_proto.operation * error list) Operation_hash.Map.t;
        branch_delayed :
          (Next_proto.operation * error list) Operation_hash.Map.t;
        unprocessed : Next_proto.operation Operation_hash.Map.t;
      }

      let version_0_encoding =
        conv
          (fun {
                 applied;
                 refused;
                 outdated;
                 branch_refused;
                 branch_delayed;
                 unprocessed;
               } ->
            ( applied,
              refused,
              outdated,
              branch_refused,
              branch_delayed,
              unprocessed ))
          (fun ( applied,
                 refused,
                 outdated,
                 branch_refused,
                 branch_delayed,
                 unprocessed ) ->
            {
              applied;
              refused;
              outdated;
              branch_refused;
              branch_delayed;
              unprocessed;
            })
          (obj6
             (req
                "applied"
                (list
                   (conv
                      (fun (hash, (op : Next_proto.operation)) ->
                        ((hash, op.shell), op.protocol_data))
                      (fun ((hash, shell), protocol_data) ->
                        (hash, {shell; protocol_data}))
                      (merge_objs
                         (merge_objs
                            (obj1 (req "hash" Operation_hash.encoding))
                            (dynamic_size Operation.shell_header_encoding))
                         (dynamic_size Next_proto.operation_data_encoding)))))
             (req
                "refused"
                (Operation_hash.Map.encoding
                   (merge_objs
                      (dynamic_size next_operation_encoding)
                      (obj1 (req "error" Tezos_rpc.Error.encoding)))))
             (req
                "outdated"
                (Operation_hash.Map.encoding
                   (merge_objs
                      (dynamic_size next_operation_encoding)
                      (obj1 (req "error" Tezos_rpc.Error.encoding)))))
             (req
                "branch_refused"
                (Operation_hash.Map.encoding
                   (merge_objs
                      (dynamic_size next_operation_encoding)
                      (obj1 (req "error" Tezos_rpc.Error.encoding)))))
             (req
                "branch_delayed"
                (Operation_hash.Map.encoding
                   (merge_objs
                      (dynamic_size next_operation_encoding)
                      (obj1 (req "error" Tezos_rpc.Error.encoding)))))
             (req
                "unprocessed"
                (Operation_hash.Map.encoding
                   (dynamic_size next_operation_encoding))))

      let version_1_encoding =
        let operations_with_error_encoding kind =
          req
            kind
            (conv
               (fun map -> Operation_hash.Map.bindings map)
               (fun list -> list |> List.to_seq |> Operation_hash.Map.of_seq)
               (list
                  (merge_objs
                     (obj1 (req "hash" Operation_hash.encoding))
                     (merge_objs
                        next_operation_encoding
                        (obj1 (req "error" Tezos_rpc.Error.encoding))))))
        in
        conv
          (fun {
                 applied;
                 refused;
                 outdated;
                 branch_refused;
                 branch_delayed;
                 unprocessed;
               } ->
            ( applied,
              refused,
              outdated,
              branch_refused,
              branch_delayed,
              unprocessed ))
          (fun ( applied,
                 refused,
                 outdated,
                 branch_refused,
                 branch_delayed,
                 unprocessed ) ->
            {
              applied;
              refused;
              outdated;
              branch_refused;
              branch_delayed;
              unprocessed;
            })
          (obj6
             (req
                "applied"
                (list
                   (conv
                      (fun (hash, (op : Next_proto.operation)) ->
                        ((hash, op.shell), op.protocol_data))
                      (fun ((hash, shell), protocol_data) ->
                        (hash, {shell; protocol_data}))
                      (merge_objs
                         (merge_objs
                            (obj1 (req "hash" Operation_hash.encoding))
                            Operation.shell_header_encoding)
                         (dynamic_size Next_proto.operation_data_encoding)))))
             (operations_with_error_encoding "refused")
             (operations_with_error_encoding "outdated")
             (operations_with_error_encoding "branch_refused")
             (operations_with_error_encoding "branch_delayed")
             (req
                "unprocessed"
                (conv
                   (fun map -> Operation_hash.Map.bindings map)
                   (fun list ->
                     list |> List.to_seq |> Operation_hash.Map.of_seq)
                   (list
                      (merge_objs
                         (obj1 (req "hash" Operation_hash.encoding))
                         next_operation_encoding)))))

      (* This encoding should be always the one by default. *)
      let encoding = version_1_encoding

      (* If you change this value, also change [encoding]. *)
      let default_pending_operations_version = 1

      let pending_query =
        let open Tezos_rpc.Query in
        query
          (fun
            version
            applied
            refused
            outdated
            branch_refused
            branch_delayed
            validation_passes
          ->
            object
              method version = version

              method applied = applied

              method refused = refused

              method outdated = outdated

              method branch_refused = branch_refused

              method branch_delayed = branch_delayed

              method validation_passes = validation_passes
            end)
        |+ field
             "version"
             Tezos_rpc.Arg.int
             default_pending_operations_version
             (fun t -> t#version)
        |+ field
             ~descr:"Include applied operations (true by default)"
             "applied"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#applied)
        |+ field
             ~descr:"Include refused operations (true by default)"
             "refused"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#refused)
        |+ field
             ~descr:"Include outdated operations (true by default)"
             "outdated"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#outdated)
        |+ field
             ~descr:"Include branch refused operations (true by default)"
             "branch_refused"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#branch_refused)
        |+ field
             ~descr:"Include branch delayed operations (true by default)"
             "branch_delayed"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#branch_delayed)
        |+ multi_field
             ~descr:
               "Include operations filtered by validation pass (all by default)"
             "validation_pass"
             Tezos_rpc.Arg.int
             (fun t -> t#validation_passes)
        |> seal

      (* If you update this datatype, please update also [supported_version]. *)
      type t_with_version = Version_0 of t | Version_1 of t

      (* This value should be consistent with [t_with_version]. *)
      let supported_version = [0; 1]

      let pending_operations_encoding =
        union
          [
            case
              ~title:"new_encoding_pending_operations"
              (Tag 1)
              version_1_encoding
              (function
                | Version_1 pending_operations -> Some pending_operations
                | Version_0 _ -> None)
              (fun pending_operations -> Version_1 pending_operations);
            case
              ~title:"old_encoding_pending_operations"
              Json_only
              version_0_encoding
              (function
                | Version_0 pending_operations -> Some pending_operations
                | Version_1 _ -> None)
              (fun pending_operations -> Version_0 pending_operations);
          ]

      let pending_operations_version_dispatcher ~version pending_operations =
        if version = 0 then
          Tezos_rpc.Answer.return (Version_0 pending_operations)
        else if version = 1 then
          Tezos_rpc.Answer.return (Version_1 pending_operations)
        else
          Tezos_rpc.Answer.fail
            (Tezos_rpc.Error.bad_version
               ~given:version
               ~supported:supported_version)

      let pending_operations path =
        Tezos_rpc.Service.get_service
          ~description:"List the prevalidated operations."
          ~query:pending_query
          ~output:pending_operations_encoding
          Tezos_rpc.Path.(path / "pending_operations")

      let ban_operation path =
        Tezos_rpc.Service.post_service
          ~description:
            "Remove an operation from the mempool if present, reverting its \
             effect if it was applied. Add it to the set of banned operations \
             to prevent it from being fetched/processed/injected in the \
             future. Note: If the baker has already received the operation, \
             then it's necessary to restart it to flush the operation from it."
          ~query:Tezos_rpc.Query.empty
          ~input:Operation_hash.encoding
          ~output:unit
          Tezos_rpc.Path.(path / "ban_operation")

      let unban_operation path =
        Tezos_rpc.Service.post_service
          ~description:
            "Remove an operation from the set of banned operations (nothing \
             happens if it was not banned)."
          ~query:Tezos_rpc.Query.empty
          ~input:Operation_hash.encoding
          ~output:unit
          Tezos_rpc.Path.(path / "unban_operation")

      let unban_all_operations path =
        Tezos_rpc.Service.post_service
          ~description:"Clear the set of banned operations."
          ~query:Tezos_rpc.Query.empty
          ~input:Data_encoding.empty
          ~output:unit
          Tezos_rpc.Path.(path / "unban_all_operations")

      let mempool_query =
        let open Tezos_rpc.Query in
        query
          (fun
            applied
            refused
            outdated
            branch_refused
            branch_delayed
            validation_passes
          ->
            object
              method applied = applied

              method refused = refused

              method outdated = outdated

              method branch_refused = branch_refused

              method branch_delayed = branch_delayed

              method validation_passes = validation_passes
            end)
        |+ field
             ~descr:"Include applied operations (set by default)"
             "applied"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#applied)
        |+ field
             ~descr:"Include refused operations"
             "refused"
             Tezos_rpc.Arg.bool
             false
             (fun t -> t#refused)
        |+ field
             ~descr:"Include outdated operations"
             "outdated"
             Tezos_rpc.Arg.bool
             false
             (fun t -> t#outdated)
        |+ field
             ~descr:"Include branch refused operations"
             "branch_refused"
             Tezos_rpc.Arg.bool
             false
             (fun t -> t#branch_refused)
        |+ field
             ~descr:"Include branch delayed operations (set by default)"
             "branch_delayed"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#branch_delayed)
        |+ multi_field
             ~descr:
               "Include operations filtered by validation pass (all by default)"
             "validation_pass"
             Tezos_rpc.Arg.int
             (fun t -> t#validation_passes)
        |> seal

      (* We extend the object so that the fields of 'next_operation'
         stay toplevel, for backward compatibility. *)
      let processed_operation_encoding =
        merge_objs
          (merge_objs
             (obj1 (req "hash" Operation_hash.encoding))
             next_operation_encoding)
          (obj1 (dft "error" Tezos_rpc.Error.opt_encoding None))

      let monitor_operations path =
        Tezos_rpc.Service.get_service
          ~description:"Monitor the mempool operations."
          ~query:mempool_query
          ~output:(list processed_operation_encoding)
          Tezos_rpc.Path.(path / "monitor_operations")

      let get_filter_query =
        let open Tezos_rpc.Query in
        query (fun include_default ->
            object
              method include_default = include_default
            end)
        |+ field
             ~descr:"Show fields equal to their default value (set by default)"
             "include_default"
             Tezos_rpc.Arg.bool
             true
             (fun t -> t#include_default)
        |> seal

      let get_filter path =
        Tezos_rpc.Service.get_service
          ~description:
            {|Get the configuration of the mempool filter. The minimal_fees are in mutez. Each field minimal_nanotez_per_xxx is a rational number given as a numerator and a denominator, e.g. "minimal_nanotez_per_gas_unit": [ "100", "1" ].|}
          ~query:get_filter_query
          ~output:json
          Tezos_rpc.Path.(path / "filter")

      let set_filter path =
        Tezos_rpc.Service.post_service
          ~description:
            {|Set the configuration of the mempool filter. **If any of the fields is absent from the input JSON, then it is set to the default value for this field (i.e. its value in the default configuration), even if it previously had a different value.** If the input JSON does not describe a valid configuration, then the configuration is left unchanged. Also return the new configuration (which may differ from the input if it had omitted fields or was invalid). You may call [./octez-client rpc get '/chains/main/mempool/filter?include_default=true'] to see an example of JSON describing a valid configuration.|}
          ~query:Tezos_rpc.Query.empty
          ~input:json
          ~output:json
          Tezos_rpc.Path.(path / "filter")

      let request_operations_query =
        let open Tezos_rpc.Query in
        query (fun peer_id ->
            object
              method peer_id = peer_id
            end)
        |+ opt_field "peer_id" P2p_peer_id.rpc_arg (fun t -> t#peer_id)
        |> seal

      let request_operations path =
        Tezos_rpc.Service.post_service
          ~description:
            "Request the operations of our peers or a specific peer if \
             specified via a query parameter."
          ~input:Data_encoding.empty
          ~query:request_operations_query
          ~output:Data_encoding.empty
          Tezos_rpc.Path.(path / "request_operations")
    end

    let live_blocks =
      Tezos_rpc.Service.get_service
        ~description:
          "List the ancestors of the given block which, if referred to as the \
           branch in an operation header, are recent enough for that operation \
           to be included in the current block."
        ~query:Tezos_rpc.Query.empty
        ~output:Block_hash.Set.encoding
        Tezos_rpc.Path.(live_blocks_path open_root)
  end

  let path = Tezos_rpc.Path.prefix chain_path path

  let make_call0 s ctxt a b q p =
    let s = Tezos_rpc.Service.prefix path s in
    Tezos_rpc.Context.make_call2 s ctxt a b q p

  let make_call1 s ctxt a b c q p =
    let s = Tezos_rpc.Service.prefix path s in
    Tezos_rpc.Context.make_call3 s ctxt a b c q p

  let make_call2 s ctxt a b c d q p =
    let s = Tezos_rpc.Service.prefix path s in
    Tezos_rpc.Context.make_call s ctxt (((((), a), b), c), d) q p

  let hash ctxt =
    let f = make_call0 S.hash ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () ->
      match block with
      | `Hash (h, 0) -> Lwt.return_ok h
      | _ -> f chain block () ()

  let header ctxt =
    let f = make_call0 S.header ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  let raw_header ctxt =
    let f = make_call0 S.raw_header ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  let metadata ctxt =
    let f = make_call0 S.metadata ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  let metadata_hash ctxt =
    let f = make_call0 S.metadata_hash ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  let protocols ctxt =
    let f = make_call0 S.protocols ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  let resulting_context_hash ctxt =
    let f = make_call0 S.resulting_context_hash ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

  module Header = struct
    module S = S.Header

    let shell_header ctxt =
      let f = make_call0 S.shell_header ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

    let protocol_data ctxt =
      let f = make_call0 S.protocol_data ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

    let raw_protocol_data ctxt =
      let f = make_call0 S.raw_protocol_data ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()
  end

  module Operations = struct
    module S = S.Operations

    let operations ctxt ?(force_metadata = false) ?metadata =
      let f = make_call0 S.operations ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () ->
        f
          chain
          block
          (object
             method force_metadata = force_metadata

             method metadata = metadata
          end)
          ()

    let operations_in_pass ctxt ?(force_metadata = false) ?metadata =
      let f = make_call1 S.operations_in_pass ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n ->
        f
          chain
          block
          n
          (object
             method force_metadata = force_metadata

             method metadata = metadata
          end)
          ()

    let operation ctxt ?(force_metadata = false) ?metadata =
      let f = make_call2 S.operation ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n m ->
        f
          chain
          block
          n
          m
          (object
             method force_metadata = force_metadata

             method metadata = metadata
          end)
          ()
  end

  module Operation_hashes = struct
    module S = S.Operation_hashes

    let operation_hashes ctxt =
      let f = make_call0 S.operation_hashes ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

    let operation_hashes_in_pass ctxt =
      let f = make_call1 S.operation_hashes_in_pass ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n -> f chain block n () ()

    let operation_hash ctxt =
      let f = make_call2 S.operation_hash ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n m -> f chain block n m () ()
  end

  module Operation_metadata_hashes = struct
    module S = S.Operation_metadata_hashes

    let root ctxt =
      let f = make_call0 S.root ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

    let operation_metadata_hashes ctxt =
      let f = make_call0 S.operation_metadata_hashes ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()

    let operation_metadata_hashes_in_pass ctxt =
      let f = make_call1 S.operation_metadata_hashes_in_pass ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n -> f chain block n () ()

    let operation_metadata_hash ctxt =
      let f = make_call2 S.operation_metadata_hash ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) n m -> f chain block n m () ()
  end

  module Context = struct
    module S = S.Context

    let read ctxt =
      let f = make_call1 S.read ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) ?depth path ->
        f
          chain
          block
          path
          (object
             method depth = depth
          end)
          ()

    let merkle_tree ctxt =
      let f = make_call1 S.merkle_tree_v2 ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) ?holey path ->
        f
          chain
          block
          path
          (object
             method holey = holey
          end)
          ()
  end

  module Helpers = struct
    module S = S.Helpers

    module Forge = struct
      module S = S.Forge

      let block_header ctxt =
        let f = make_call0 S.block_header ctxt in
        fun ?(chain = `Main) ?(block = `Head 0) header ->
          f chain block () header
    end

    module Preapply = struct
      module S = S.Preapply

      let block ctxt =
        let f = make_call0 S.block ctxt in
        fun ?(chain = `Main)
            ?(block = `Head 0)
            ?(sort = false)
            ?timestamp
            ~protocol_data
            operations ->
          f
            chain
            block
            (object
               method sort_operations = sort

               method timestamp = timestamp
            end)
            {protocol_data; operations}

      let operations ctxt =
        let f = make_call0 S.operations ctxt in
        fun ?(chain = `Main) ?(block = `Head 0) operations ->
          f chain block () operations
    end

    let complete ctxt =
      let f = make_call1 S.complete ctxt in
      fun ?(chain = `Main) ?(block = `Head 0) s -> f chain block s () ()
  end

  let info ctxt ?(force_metadata = false) ?metadata =
    let f = make_call0 S.info ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () ->
      f
        chain
        block
        (object
           method force_metadata = force_metadata

           method metadata = metadata
        end)
        ()

  module Mempool = struct
    type t = S.Mempool.t = {
      applied : (Operation_hash.t * Next_proto.operation) list;
      refused : (Next_proto.operation * error list) Operation_hash.Map.t;
      outdated : (Next_proto.operation * error list) Operation_hash.Map.t;
      branch_refused : (Next_proto.operation * error list) Operation_hash.Map.t;
      branch_delayed : (Next_proto.operation * error list) Operation_hash.Map.t;
      unprocessed : Next_proto.operation Operation_hash.Map.t;
    }

    type t_with_version = S.Mempool.t_with_version =
      | Version_0 of t
      | Version_1 of t

    let pending_operations_version_dispatcher =
      S.Mempool.pending_operations_version_dispatcher

    let pending_operations ctxt ?(chain = `Main)
        ?(version = S.Mempool.default_pending_operations_version)
        ?(applied = true) ?(branch_delayed = true) ?(branch_refused = true)
        ?(refused = true) ?(outdated = true) ?(validation_passes = []) () =
      let open Lwt_result_syntax in
      let* v =
        Tezos_rpc.Context.make_call1
          (S.Mempool.pending_operations (mempool_path chain_path))
          ctxt
          chain
          (object
             method version = version

             method applied = applied

             method refused = refused

             method outdated = outdated

             method branch_refused = branch_refused

             method branch_delayed = branch_delayed

             method validation_passes = validation_passes
          end)
          ()
      in
      match v with
      | Version_1 pending_operations | Version_0 pending_operations ->
          return pending_operations

    let ban_operation ctxt ?(chain = `Main) op_hash =
      let s = S.Mempool.ban_operation (mempool_path chain_path) in
      Tezos_rpc.Context.make_call1 s ctxt chain () op_hash

    let unban_operation ctxt ?(chain = `Main) op_hash =
      let s = S.Mempool.unban_operation (mempool_path chain_path) in
      Tezos_rpc.Context.make_call1 s ctxt chain () op_hash

    let unban_all_operations ctxt ?(chain = `Main) () =
      let s = S.Mempool.unban_all_operations (mempool_path chain_path) in
      Tezos_rpc.Context.make_call1 s ctxt chain () ()

    let monitor_operations ctxt ?(chain = `Main) ?(applied = true)
        ?(branch_delayed = true) ?(branch_refused = false) ?(refused = false)
        ?(outdated = false) ?(validation_passes = []) () =
      let s = S.Mempool.monitor_operations (mempool_path chain_path) in
      Tezos_rpc.Context.make_streamed_call
        s
        ctxt
        ((), chain)
        (object
           method applied = applied

           method refused = refused

           method outdated = outdated

           method branch_refused = branch_refused

           method branch_delayed = branch_delayed

           method validation_passes = validation_passes
        end)
        ()

    let request_operations ctxt ?(chain = `Main) ?peer_id () =
      let s = S.Mempool.request_operations (mempool_path chain_path) in
      Tezos_rpc.Context.make_call1
        s
        ctxt
        chain
        (object
           method peer_id = peer_id
        end)
        ()
  end

  let live_blocks ctxt =
    let f = make_call0 S.live_blocks ctxt in
    fun ?(chain = `Main) ?(block = `Head 0) () -> f chain block () ()
end

module Fake_protocol = struct
  let hash = Protocol_hash.zero

  type block_header_data = unit

  let block_header_data_encoding = Data_encoding.empty

  type block_header_metadata = unit

  let block_header_metadata_encoding = Data_encoding.empty

  type operation_data = unit

  type operation_receipt = unit

  type operation = {
    shell : Operation.shell_header;
    protocol_data : operation_data;
  }

  let operation_data_encoding = Data_encoding.empty

  let operation_receipt_encoding = Data_encoding.empty

  let operation_data_and_receipt_encoding =
    Data_encoding.conv
      (fun ((), ()) -> ())
      (fun () -> ((), ()))
      Data_encoding.empty
end

module Empty = Make (Fake_protocol) (Fake_protocol)

let () =
  Printexc.register_printer (function
      | ( Json_schema.Cannot_parse _ | Json_schema.Dangling_reference _
        | Json_schema.Bad_reference _ | Json_schema.Unexpected _
        | Json_schema.Duplicate_definition _ ) as exn ->
          Some
            (Format.asprintf "%a" (fun ppf -> Json_schema.print_error ppf) exn)
      | _ -> None)

let protocols = Empty.protocols
