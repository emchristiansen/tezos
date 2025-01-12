(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* Testing
   -------
   Component:    P2P
   Invocation:   dune exec tezt/tests/main.exe -- --file p2p.ml
   Subject:      Integration tests of p2p layer.
*)

module ACL = struct
  (* Test.

     Check IP address greylisting mechanism with unauthenticated connection.

     1. Start a node,
     2. Write noise on the welcome worker of this node,
     3. Check the IP greylist with a RPC,
     4. Try to connect to a greylisted node. *)
  let check_ip_greylisting () =
    let pp_list ~elt_pp l =
      let rec pp_rec ~elt_pp ppf = function
        | [] -> ()
        | [elt] -> Format.fprintf ppf "%a" elt_pp elt
        | head :: tail ->
            Format.fprintf ppf "%a, " elt_pp head ;
            pp_rec ~elt_pp ppf tail
      in
      Format.asprintf "[%a]" (pp_rec ~elt_pp) l
    in
    Test.register
      ~__FILE__
      ~title:"check ip greylisting"
      ~tags:["p2p"; "acl"; "greylist"]
    @@ fun () ->
    let localhost_ips =
      [
        (* 127.0.0.1 *)
        Unix.inet_addr_loopback;
        (* ::1 *)
        Unix.inet6_addr_loopback;
        Unix.inet_addr_of_string "::ffff:127.0.0.1";
        Unix.inet_addr_of_string "::ffff:7f00:0001";
      ]
    in
    let* target = Node.init [] in
    let* node = Node.init [] in
    let* client = Client.init ~endpoint:(Node target) () in
    let* () =
      Node.send_raw_data
        target
        ~data:"\000\010Hello, world. This is garbage, greylist me !"
    in
    let* json = RPC.Client.call client RPC.get_network_greylist_ips in
    let greylisted_ips = JSON.(as_list (json |-> "ips")) in
    let nb_greylisted_ips = List.length greylisted_ips in
    if nb_greylisted_ips <> 1 then
      Test.fail
        "The number of greylisted IPs is incorrect (actual: %d, expected: 1)."
        nb_greylisted_ips ;
    let greylisted_ip =
      Unix.inet_addr_of_string (JSON.as_string (List.hd greylisted_ips))
    in
    if List.for_all (( <> ) greylisted_ip) localhost_ips then
      Test.fail
        "The greylisted IP is incorrect (actual: %s, expected: one of %s)."
        (Unix.string_of_inet_addr greylisted_ip)
        (pp_list
           ~elt_pp:(fun ppf ip ->
             Format.fprintf ppf "%s" (Unix.string_of_inet_addr ip))
           localhost_ips) ;
    let process = Client.Admin.spawn_connect_address ~peer:node client in
    let error_rex =
      rex "Error:(\n|.)*The address you tried to connect \\(.*\\) is banned."
    in
    Process.check_error ~msg:error_rex process

  let tests () = check_ip_greylisting ()
end

(* [wait_for_accepted_peer_ids] waits until the node connects to a peer for
   which an expected [peer_id] was set. *)
let wait_for_accepted_peer_ids node =
  let filter _ = Some () in
  Node.wait_for node "authenticate_status_peer_id_correct.v0" filter

(* Test.

   We start two nodes. We connect one node with the other using the
   `--peer` option and by setting an expected peer_id. To check that the nodes
   are connected, we activate the protocol and check that the block 1 has been
   propagated. *)
let check_peer_option =
  Protocol.register_test
    ~__FILE__
    ~title:"check peer option"
    ~tags:["p2p"; "cli"; "peer"]
  @@ fun protocol ->
  let* node_1 = Node.init [Synchronisation_threshold 0] in
  let* client = Client.init ~endpoint:(Node node_1) () in
  let* () = Client.activate_protocol_and_wait ~protocol client in
  let node_2 = Node.create [] in
  let wait = wait_for_accepted_peer_ids node_2 in
  let* () = Node.identity_generate node_2 in
  let* () = Node.config_init node_2 [] in
  let* () = Node.add_peer_with_id node_2 node_1 in
  let* () = Node.run node_2 [] in
  let* () = Node.wait_for_ready node_2 in
  let* () = wait in
  let* _ = Node.wait_for_level node_2 1 in
  unit

(* Test.

   We create one node with the `--connections` option set to 1 and another one
   with no specification. Then, we use the `--peer` option to let the p2p
   maintenance of the first node establishes a connection with the other node.
   To check the nodes are connected, we activate the protocol and check that
   the block 1 has been propagated. *)

let test_one_connection =
  let nb_connection = 1 in
  Protocol.register_test
    ~__FILE__
    ~title:"check --connection=1 option"
    ~tags:["p2p"; "cli"; "connections"]
  @@ fun protocol ->
  let* node_1 = Node.init [Synchronisation_threshold 0] in
  let* client = Client.init ~endpoint:(Node node_1) () in
  let* () = Client.activate_protocol_and_wait ~protocol client in
  let node_2 = Node.create [Connections nb_connection] in
  let wait = wait_for_accepted_peer_ids node_2 in
  let* () = Node.identity_generate node_2 in
  let* () = Node.config_init node_2 [] in
  let* () = Node.add_peer_with_id node_2 node_1 in
  let* () = Node.run node_2 [] in
  let* () = Node.wait_for_ready node_2 in
  let* () = wait in
  let* _ = Node.wait_for_level node_2 1 in
  unit

(* [wait_pred] waits until [pred arg] is true. An active wait with Lwt
   cooperation points is used. *)
let rec wait_pred ~pred ~arg =
  let* () = Lwt.pause () in
  let* cond = pred arg in
  if not cond then wait_pred ~pred ~arg else unit

(* [get_nb_connections ~client] returns the number of active connections of the
   node  to [client]. *)
let get_nb_connections node =
  let* ports = RPC.call node RPC.get_network_connections in
  return @@ List.length ports

(* [wait_connections ~client n] waits until the node related to [client] has at
   least [n] active connections. *)
let wait_connections node nb_conns_target =
  wait_pred
    ~pred:(fun () ->
      let* nb_conns = get_nb_connections node in
      return @@ (nb_conns >= nb_conns_target))
    ~arg:()

module Maintenance = struct
  (*
     The following test checks that when the maintenance is
     deactivated by the configuration file of the node, the
     maintenance is not triggered.

     To do so, we run two nodes, one with the maintenance activated
     and one without.

     We use a third node as a target node to see whether the two
     previous node can connect to it. Only the one with the
     maintenance activated can. To trigger two steps of maintenance,
     we restart the target node.

     Meanwhile, we check that when the time for two maintenance steps
     has elapsed, the node with the maintenance deactivated did not
     trigger any maintenance step. *)
  let test_disabled () =
    Test.register
      ~__FILE__
      ~title:"p2p-maintenance-disabled"
      ~tags:["p2p"; "node"; "maintenance"]
    @@ fun () ->
    (* We set the maintenance idle time to 5 seconds to make the test
       shorter. *)
    let maintenance_idle_time = 5. in
    (* [create_node name peer] initializes a node with:
       - the name [name],
       - a modified maintenance idle time,
       - 1 expected number of connections,
       - [peer] as known peer *)
    let create_node name peer =
      let patch_config =
        JSON.update
          "p2p"
          (JSON.update
             "limits"
             (JSON.put
                ( "maintenance-idle-time",
                  JSON.parse
                    ~origin:__LOC__
                    (Float.to_string maintenance_idle_time) )))
      in
      let node = Node.create ~name [Connections 1] in
      Node.add_peer node peer ;
      let* () = Node.identity_generate node in
      let* () = Node.config_init node [] in
      Node.Config_file.update node patch_config ;
      return node
    in
    let run_node node params =
      let* () = Node.run node params in
      Node.wait_for_ready node
    in
    (* [target_node] is the node that will be known by both
       [disabled_node] and [enabled_node].  Note that this is not
       symmetric, [neighbour_node] doesn't know the two others so
       should not initiate connections. *)
    let* target_node = Node.init ~name:"target-node" [Connections 2] in
    (* [disabled_node] is the node that is the subject of this
       test. We try to verify that it won't perform a maintenance
       pass.  Whereas it knowns the target node, it should not try to
       connect with it because the maintenance is disabled.*)
    let* disabled_node = create_node "no-maintenance-node" target_node in
    (* The test should fail if the node with the maintenance
       deactivated emits such an event. *)
    let _ =
      Node.wait_for disabled_node "maintenance_started.v0" (fun _ ->
          Test.fail "A maintenance step started on the disabled node.")
    in
    let* () = run_node disabled_node [Disable_p2p_maintenance] in
    (* This node is used to observe the maintenance steps when it is
       activated by default. Its maintenance should start by
       establishing a connection with [target_node]. To trigger the
       maintenance a second time, [target_node] is restarted.*)
    let* enabled_node = create_node "with-maintenance-node" target_node in
    (* This timer is used to check that after two steps of
       maintenance, the node with the maintenance deactivated did
       not triggered any maintenance step. *)
    let time = maintenance_idle_time *. 2. in
    let sleep_promise time = Lwt_unix.sleep time in
    let first_step_of_maintenance_started =
      Node.wait_for enabled_node "maintenance_started.v0" (fun _ -> Some ())
    in
    let first_step_of_maintenance_ended =
      Node.wait_for enabled_node "maintenance_ended.v0" (fun _ -> Some ())
    in
    let* () = run_node enabled_node [] in
    let* () = first_step_of_maintenance_started in
    let* () = first_step_of_maintenance_ended in
    Log.info "The first maintenance step of enabled node ended." ;

    let second_step_of_maintenance_started =
      Node.wait_for enabled_node "maintenance_started.v0" (fun _ -> Some ())
    in
    let* () = Node.terminate target_node in
    (* Restart the neighbour to trigger the maintenance. *)
    let* () = second_step_of_maintenance_started in
    Log.info "The second maintenance step of enabled node started." ;

    let second_step_of_maintenance_ended =
      Node.wait_for enabled_node "maintenance_ended.v0" (fun _ -> Some ())
    in
    (* FIXME: https://gitlab.com/tezos/tezos/-/issues/4782

       We should dlete the peer.json file of [target_node] to be sure
       it will not initiate a connection. However, by doing so, the
       test can be stuck for a while with no connection. This could be
       due to the reconnection delay maybe? *)
    (* Node.remove_peers_json_file neighbour_node ; *)
    let* () = Node.run target_node [] in
    let* () = second_step_of_maintenance_ended in
    Log.info "The second maintenance step of enabled node ended." ;

    (* Waits twice the [maintenance_idle_time] to check that the maintenance of
       [disabled_node] is not triggered by the timer. *)
    let* () = sleep_promise time in
    Log.info "%f secons elapsed corresponding to two steps of maintenance" time ;
    unit

  (* Test.
     Initialize a node and verify that the number of active connections
     established by the maintenance is correct. *)
  let test_expected_connections () =
    (* The value of [expected_connections] is fixed to 6 in this test for two
       reasons. Firstly, the consumption of each node is substantial and there
       will be [expected_connection*2/3+1] nodes launched. This explains why the
       number of [expected_connections] is quite small. Secondly, since the
       values of the maintenance configuration are integers, there will be an
       approximation and then for a small value, it is required to have
       [expected_connections mod 6 = 0]. *)
    let expected_connections = 6 in
    Test.register
      ~__FILE__
      ~title:"p2p-maintenance-init-expected_connections"
      ~tags:["p2p"; "node"; "maintenance"]
    @@ fun () ->
    (* Connections values evaluated from --connections option. *)
    let min_connections = expected_connections / 2 in
    let max_connections = 3 * expected_connections / 2 in
    (* Connections values evaluated from P2p_maintenance.config. *)
    let step_min = (expected_connections - min_connections) / 3
    and step_max = (max_connections - expected_connections) / 3 in
    let min_threshold = min_connections + step_min in
    (* The target variables are used to define the goal interval of active
       connections reached by the maintenance. *)
    let min_target = min_connections + (2 * step_min) in
    let max_target = max_connections - (2 * step_max) in
    let max_threshold = max_connections - step_max in
    Log.info
      "Configuration values (min: %d, min_threshold: %d, min_target: %d, \
       expected: %d, max_target: %d, max_threshold: %d, max: %d)."
      min_connections
      min_threshold
      min_target
      expected_connections
      max_target
      max_threshold
      max_connections ;
    let* target_node = Node.init [Connections expected_connections] in
    let* target_client = Client.init ~endpoint:(Node target_node) () in
    Log.info "Target created." ;
    let nodes =
      Cluster.create max_connections [Connections (max_connections - 1)]
    in
    Cluster.clique nodes ;
    let* () = Cluster.start ~public:true nodes in
    Log.info "Complete network of nodes created." ;
    let maintenance_ended_promise =
      Node.wait_for target_node "maintenance_ended.v0" (fun _ -> Some ())
    in
    let* () =
      Client.Admin.connect_address target_client ~peer:(List.hd nodes)
    in
    Log.info "Target is connected to the network." ;
    let* () = wait_connections target_node min_target in
    Log.info "Enough connections has been established." ;
    let* () = maintenance_ended_promise in
    Log.info "The maintenance ended." ;
    let* nb_active_connections = get_nb_connections target_node in
    if nb_active_connections > max_target then
      Test.fail
        "There are too many active connections (actual: %d, expected less than \
         %d)"
        nb_active_connections
        max_target ;
    unit

  let tests () =
    test_disabled () ;
    test_expected_connections ()
end

let port_from_peers_file file_name =
  JSON.parse_file file_name |> JSON.geti 0
  |> JSON.get "last_established_connection"
  |> JSON.geti 0 |> JSON.get "port" |> JSON.as_int

(*
  - node_2 connects to the peer node_1 and advertises different listening port
  - after node_1 receives advertised net port from node_2 (maintenance_ended),
    terminate node_1 to force it saving peer metadata;
  - check that saved node_1 peer metadata contains net port advertised by node_2,
    not its actual listening net port
*)
let test_advertised_port () =
  Test.register
    ~__FILE__
    ~title:"check --advertised-net-port=PORT option"
    ~tags:["p2p"; "cli"; "connections"]
  @@ fun () ->
  let* node_1 = Node.init [Connections 1] in
  let maintenance_p =
    Node.wait_for node_1 "maintenance_ended.v0" (fun _ -> Some ())
  in

  let advertised_net_port = Port.fresh () in
  let node_2 = Node.create ~advertised_net_port [] in
  let* () = Node.identity_generate node_2 in
  let* () = Node.config_init node_2 [] in
  let () = Node.add_peer node_2 node_1 in

  let* () = Node.run node_2 [] in
  let* () = Node.wait_for_ready node_2 in
  let* () = maintenance_p in

  let wait_for_save_p =
    Node.wait_for node_1 "save_metadata.v0" (fun json ->
        Some (JSON.as_string json))
  in

  let* () = Node.terminate node_1 in

  let* path = wait_for_save_p in
  let advertised_port_from_peers_file = port_from_peers_file path in
  if advertised_port_from_peers_file <> advertised_net_port then
    Test.fail
      "advertised-net-port: Unexpected port number received (got %d, expeted \
       %d)"
      advertised_port_from_peers_file
      advertised_net_port
  else () ;

  unit

let known_points node =
  let* points = RPC.(call node get_network_points) in
  return
  @@ List.map
       (fun (str, _) ->
         match String.split_on_char ':' str with
         | [addr; port] -> (addr, int_of_string port)
         | _ -> Test.fail "Unexpected output from [get_network_points]: %s" str)
       points

module Known_Points_GC = struct
  (* Create a node that accept only
     1 point in its known points set *)
  let create_node () =
    let node = Node.create [Connections 0] in
    let* () = Node.identity_generate node in
    let* () = Node.config_init node [] in
    let () =
      Node.Config_file.update
        node
        (JSON.update
           "p2p"
           (JSON.update
              "limits"
              (JSON.put
                 ("max_known_points", JSON.parse ~origin:__LOC__ "[0,0]"))))
      (* Here we set the max known point to 0 as there is an off-by-one error on
         the max size interpretation in lib_p2p as GC is triggered just before
         adding one element.
         What we actually get is a set of size 1.
      *)
    in
    return node

  let included ~sub ~super ~fail =
    List.iter
      (fun data -> if not @@ List.mem data super then fail data else ())
      sub

  let test_trusted_preservation () =
    Test.register
      ~__FILE__
      ~title:"check preservation of trusted known points and peers"
      ~tags:["p2p"; "pool"; "gc"]
    @@ fun () ->
    let* node_1 = create_node () in
    let nodes = List.init 6 (fun _ -> Node.create []) in
    let* () = Node.run node_1 [] in
    let* () = Node.wait_for_ready node_1 in
    let* client = Client.init ~endpoint:(Node node_1) () in
    (* register (as trusted) the nodes, they are more max_known_points *)
    let* () =
      Lwt_list.iter_s
        (fun node -> Client.Admin.trust_address ~peer:node client)
        nodes
    in
    let* known_points = known_points node_1 in
    let registered_points = List.map Node.point nodes in
    (* check that all trusted nodes remains in the known points list *)
    included
      ~sub:registered_points
      ~super:known_points
      ~fail:(fun (addr, port) ->
        Test.fail "point %s:%d should be known" addr port) ;
    included
      ~sub:known_points
      ~super:registered_points
      ~fail:(fun (addr, port) ->
        Test.fail "point %s:%d should not be known" addr port) ;
    unit

  let test_non_trusted_removal () =
    Test.register
      ~__FILE__
      ~title:"check non-preservation of known points"
      ~tags:["p2p"; "pool"; "gc"]
    @@ fun () ->
    let* node_1 = create_node () in
    let node_A = Node.create [] in
    let nodes = List.init 3 (fun _ -> Node.create []) in
    let* () = Node.run node_1 [] in
    let* () = Node.wait_for_ready node_1 in

    let* client = Client.init ~endpoint:(Node node_1) () in
    (* trust all the nodes  to register them in known points
       and then untrust all the nodes but node_A
    *)
    let* () = Client.Admin.trust_address ~peer:node_A client in
    let* () =
      Lwt_list.iter_s
        (fun node -> Client.Admin.trust_address ~peer:node client)
        nodes
    in
    let* () =
      Lwt_list.iter_s
        (fun node -> Client.Admin.untrust_address ~peer:node client)
        nodes
    in
    (* register a new node to trigger the GC *)
    let node_B = Node.create [] in
    let* () = Client.Admin.trust_address ~peer:node_B client in
    let* known_points = known_points node_1 in
    let registered_points = List.map Node.point [node_A; node_B] in
    (* check that only node_A and
       node_B remains in the known points list *)
    included
      ~sub:registered_points
      ~super:known_points
      ~fail:(fun (addr, port) ->
        Test.fail "point %s:%d should be known" addr port) ;
    included
      ~sub:known_points
      ~super:registered_points
      ~fail:(fun (addr, port) ->
        Test.fail "point %s:%d should not be known" addr port) ;
    unit

  let tests () =
    test_trusted_preservation () ;
    test_non_trusted_removal ()
end

module Connect_handler = struct
  (* Try to connect two nodes from different networks
     and check that the p2p handshake is rejected. *)
  let connected_peers_with_different_chain_name_test () =
    Test.register
      ~__FILE__
      ~title:"peers with different chain name"
      ~tags:["p2p"; "connect_handler"]
    @@ fun () ->
    let addr_of_port port = "127.0.0.1:" ^ string_of_int port in
    let create_node ?chain_name ?peer_port port =
      let peer_arg =
        Option.map (fun p -> Node.Peer (addr_of_port p)) peer_port
        |> Option.to_list
      in
      let node = Node.create ~net_port:port (Connections 1 :: peer_arg) in
      let* () = Node.identity_generate node in
      let* () = Node.config_init node [] in
      Option.iter
        (fun name ->
          Node.Config_file.update node (fun json ->
              (* Loads a full unsugared "ghostnet" configuration,
                 so that we can update the chain_name separately
                 without depending on a network alias. *)
              Node.Config_file.set_ghostnet_sandbox_network () json
              |> JSON.update
                   "network"
                   (JSON.put
                      ( "chain_name",
                        JSON.annotate ~origin:__LOC__ (`String name) ))))
        chain_name ;
      return node
    in
    let run_node node = Node.run ~event_level:`Debug node [] in
    let wait_for_nack node port =
      let open JSON in
      Node.wait_for node "authenticate_status.v0" (fun json ->
          let typ = json |-> "type" |> as_string in
          let point = json |-> "point" |> as_string in
          if typ = "nack" && point = addr_of_port port then Some () else None)
    in

    let port1, port2 = (Port.fresh (), Port.fresh ()) in
    let* node1 = create_node port1 in
    let* node2 = create_node ~chain_name:"__dummy__" ~peer_port:port1 port2 in

    let ready1_event = Node.wait_for_ready node1 in
    let ready2_event = Node.wait_for_ready node2 in
    let nack1_event = wait_for_nack node1 port2 in
    let nack2_event = wait_for_nack node2 port1 in

    let* () = run_node node1 in
    let* () = ready1_event in
    let* () = run_node node2 in
    let* () = ready2_event in
    let* () = nack1_event and* () = nack2_event in
    unit

  let tests () = connected_peers_with_different_chain_name_test ()
end

let iter_p l f = Lwt_list.iter_p f l

let iteri_p l f = Lwt_list.iteri_p f l

let point_is_trusted (_point, meta) = JSON.(meta |-> "trusted" |> as_bool)

let point_is_running (_point, meta) =
  JSON.(meta |-> "state" |-> "event_kind" |> as_string = "running")

let point_is_other point_id (point_id', _meta) = point_id' <> point_id

let peer_is_other peer_id (peer_id', _meta) = peer_id' <> peer_id

(* This test sets up a network of public peers (running the default p2p
   protocol), with no initial bootstrap peers. It initializes a trusted ring
   relationship, and checks that points are advertised correctly to the whole
   network. *)
let trusted_ring () =
  Test.register
    ~__FILE__
    ~title:"p2p - set a trusted ring"
    ~tags:["p2p"; "connection"; "trusted"; "ring"]
  @@ fun () ->
  let num_nodes = 5 in
  Log.info "Initialize nodes" ;
  let node_arguments = [] in
  let nodes = List.init num_nodes (fun _ -> Node.create node_arguments) in
  let* () =
    iter_p nodes @@ fun node ->
    let* () = Node.run node node_arguments in
    Node.wait_for_ready node
  in
  (* Initially, nobody knows other peers. *)
  Log.info "Check no peers at init" ;
  let* () =
    iter_p nodes @@ fun node ->
    let* points = known_points node in
    Check.(
      (List.length points = 0)
        int
        ~__LOC__
        ~error_msg:("Expected " ^ Node.name node ^ " to have %R points, got %L")) ;
    unit
  in
  Log.info "Add peers" ;
  let point_id_of_node node =
    let addr, port = Node.point node in
    sf "%s:%d" addr port
  in
  (* Set up waiters for the connection *)
  let connection_p =
    iter_p nodes @@ fun node -> Node.wait_for_connections node (num_nodes - 1)
  in
  let* () =
    iteri_p nodes @@ fun index node ->
    let neighbour_point_id =
      point_id_of_node (List.nth nodes ((index + 1) mod num_nodes))
    in
    let data = JSON.annotate ~origin:"acl" @@ `O [("acl", `String "trust")] in
    RPC.(call node @@ patch_network_point neighbour_point_id data)
  in
  Log.info "Wait for connections" ;
  let* () = connection_p in
  Log.info "Check tables" ;
  (* Test various assumptions on the point/peer tables. Each peer has
     exactly one trusted neighbor. Tables don't contain their own
     peer/point id as running and contain exactly [num_nodes - 1]
     values. *)
  (* The prefix of this test should guarantee that maintenance has
     been performed when this test is run. *)
  let* () =
    iter_p nodes @@ fun node ->
    let point_id = point_id_of_node node in
    let* peer_id = RPC.(call node @@ get_network_self) in
    let* points = RPC.(call node @@ get_network_points) in
    let* peers = RPC.(call node @@ get_network_peers) in
    let trusted_points = List.filter point_is_trusted points in
    let running_points = List.filter point_is_running points in
    (* the set of known points that are not the node itself *)
    let other_points = List.filter (point_is_other point_id) points in
    (* the set of known peers that are not the node itself *)
    let other_peers = List.filter (peer_is_other peer_id) peers in
    Check.(
      list_not_mem
        string
        ~__LOC__
        point_id
        (List.map fst running_points)
        ~error_msg:"Did not expect to find %L in the set of running points %R" ;
      list_not_mem
        string
        ~__LOC__
        peer_id
        (List.map fst peers)
        ~error_msg:"Did not expect to find %L in the set of running peers %R" ;
      (List.length trusted_points = 1)
        int
        ~__LOC__
        ~error_msg:"Expected %R trusted points, got %L" ;
      (List.length other_peers = num_nodes - 1)
        int
        ~__LOC__
        ~error_msg:"Expected %R peers, got %L" ;
      (List.length other_points = num_nodes - 1)
        int
        ~__LOC__
        ~error_msg:"Expected %R points, got %L") ;
    unit
  in
  unit

(* This test sets up a clique between a set of [M] nodes [N_1;
   ...; N_M].

   Then, for each node [N_i], it tests setting the [expected_peer_id]
   on its connection to its neighbor [next(N_i)] (where [next(N_i) =
   N_((i + 1) % M)]) to the peer id of that neighbor. It checks that
   no connections are lost.

   Secondly, for each node [N_i], it sets the [expected_peer_id] on the same
   connection (the one to neighbor [next(N_i)]) to the peer id of
   [N_i]. It checks that the node consequently loses
   two connections:
   - the connection between [N_i] and [next(N_i)]; and
   - the connection between [prev(N_i)] and [N_i] (where [prev(N_i) = N_((i + 1) % M)]),
     as [prev(N_i)] will have an erroneous [expected_peer_id]
     on its connection to [N_i]. *)
let expected_peer_id () =
  Test.register
    ~__FILE__
    ~title:"Test expected_peer_id"
    ~tags:["p2p"; "connections"; "expected_peer_id"]
  @@ fun () ->
  let num_nodes = 5 in
  Log.info "Start a clique of %d nodes" num_nodes ;
  let nodes = Cluster.create num_nodes [] in
  Cluster.clique nodes ;
  let* () = Cluster.start ~wait_connections:true nodes in
  let point_id_of_node node =
    let addr, port = Node.point node in
    sf "%s:%d" addr port
  in
  let* peer_ids =
    Lwt_list.map_s
      (fun node ->
        let* peer_id = RPC.(call node @@ get_network_self) in
        Log.info "Peer id of node %s: %s" (Node.name node) peer_id ;
        return peer_id)
      nodes
  in
  let next index = if index = num_nodes - 1 then 0 else index + 1 in
  let prev index = if index = 0 then num_nodes - 1 else index - 1 in
  Log.info "Set [expected_peer_id]" ;
  (* For all nodes [node], we set [expected_peer_id] on its
     connection to its neighbor [next(node)] to the peer id of
     [next(node)]. *)
  let* () =
    iteri_p nodes @@ fun index node ->
    let neighbor_index = next index in
    let neighbor_point_id = point_id_of_node (List.nth nodes neighbor_index) in
    let neighbor_peer_id = List.nth peer_ids neighbor_index in
    let data =
      JSON.annotate ~origin:"expected_peer_id"
      @@ `O [("peer_id", `String neighbor_peer_id)]
    in
    RPC.(call node @@ patch_network_point neighbor_point_id data)
  in
  Log.info
    "Check expected_peer_id and that we still have %d connected points per node"
    (num_nodes - 1) ;
  (* For all nodes, we check that [expected_peer_id] was set
     properly. Since we set the [expected_peer_id] to the exact peer
     id of the peer already on that connection, we should not have
     lost the connection. *)
  let* () =
    iteri_p nodes @@ fun index node ->
    let neighbor_index = next index in
    let neighbor_point_id = point_id_of_node (List.nth nodes neighbor_index) in
    let* neighbor_peer =
      RPC.(call node @@ get_network_point neighbor_point_id)
    in
    Check.(
      (JSON.(neighbor_peer |-> "expected_peer_id" |> as_string)
      = List.nth peer_ids neighbor_index)
        string
        ~__LOC__
        ~error_msg:
          ("Expected the expected_peer_id of neighbor of " ^ Node.name node
         ^ " to be %R, got %L")) ;
    let* points = RPC.(call node @@ get_network_points) in
    let connected_points = List.filter point_is_running points in
    Check.(
      (List.length connected_points = num_nodes - 1)
        int
        ~__LOC__
        ~error_msg:"Expected %R connected points, got %L") ;
    unit
  in
  Log.info "Set wrong [expected_peer_id]" ;
  (* For all nodes [node], we set [expected_peer_id] on its
     connection to its neighbor [next(node)] to the peer id of
     [node]. Consequently, the node will loose two connections for
     which we set up promises here: *)
  let all_disconnections =
    iteri_p nodes @@ fun index node ->
    (* Wait for two disconnection events :
       - one between [node] and [next(node)]
       - one between [prev(node)] and [node] *)
    let wait_for_disconnect_from peer_id =
      Log.info "Node %s expects a disconnect from %s" Node.(name node) peer_id ;
      Node.wait_for node "disconnection.v0" (fun json_event ->
          let peer_id' = JSON.(json_event |> as_string) in
          if peer_id = peer_id' then (
            Log.info
              "Node %s was disconnected from %s"
              Node.(name node)
              peer_id' ;
            Some ())
          else None)
    in
    let prev_peer_id = List.nth peer_ids (prev index) in
    let next_peer_id = List.nth peer_ids (next index) in
    let* () = wait_for_disconnect_from prev_peer_id
    and* () = wait_for_disconnect_from next_peer_id in
    unit
  in
  (* Set the wrong [expected_peer_id] *)
  let* () =
    iteri_p nodes @@ fun index node ->
    let neighbor_index = next index in
    let neighbor_point_id = point_id_of_node (List.nth nodes neighbor_index) in
    let peer_id = List.nth peer_ids index in
    let data =
      JSON.annotate ~origin:"expected_peer_id"
      @@ `O [("peer_id", `String peer_id)]
    in
    RPC.(call node @@ patch_network_point neighbor_point_id data)
  in
  Log.info "Waiting for disconnections" ;
  let* () = all_disconnections in
  Log.info "Check stats with wrong expected_peer_id" ;
  (* Each node should now have two connected peers less *)
  let* () =
    iter_p nodes @@ fun node ->
    let* points = RPC.(call node @@ get_network_points) in
    let connected_points = List.filter point_is_running points in
    (* We lost two connections *)
    Check.(
      (List.length connected_points = num_nodes - 3)
        int
        ~__LOC__
        ~error_msg:"Expected %R connected points, got %L") ;
    unit
  in
  unit

module P2p_stat = struct
  type peer_id = Peer_id of string

  type point_id = {addr : Unix.inet_addr; port : int}

  let point_id_of_string s =
    match String.split_on_char ':' s |> List.rev with
    | port :: addr ->
        {
          addr = Unix.inet_addr_of_string (String.concat ":" addr);
          port = int_of_string port;
        }
    | _ -> Test.fail "[point_id_of_string] could not parse: %s" s

  let string_of_point_id {addr; port} =
    sf "%s:%d" (Unix.string_of_inet_addr addr) port

  type known_peer = {id : peer_id; connected : bool}

  let compare_known_peer peer1 peer2 =
    let {id = Peer_id peer_id1; connected = connected1} = peer1 in
    let {id = Peer_id peer_id2; connected = connected2} = peer2 in
    match String.compare peer_id1 peer_id2 with
    | 0 -> Bool.compare connected1 connected2
    | n -> n

  let pp_known_peer fmt {id = Peer_id peer_id; connected} =
    Format.fprintf fmt "{peer_id: %s; connected: %b}" peer_id connected

  let known_peer_typ = Check.comparable pp_known_peer compare_known_peer

  type known_point = {id : point_id; peer : known_peer}

  let compare_known_point point1 point2 =
    match
      String.compare
        (string_of_point_id point1.id)
        (string_of_point_id point2.id)
    with
    | 0 -> compare_known_peer point1.peer point2.peer
    | n -> n

  let known_point_typ =
    let fmt fmt {id; peer} =
      Format.fprintf
        fmt
        "{point_id: %s; %a}"
        (string_of_point_id id)
        pp_known_peer
        peer
    in
    Check.comparable fmt compare_known_point

  type p2p_stat = {
    connections : peer_id list;
    known_peers : known_peer list;
    known_points : known_point list;
  }

  let parse_p2p_stat client_output =
    let fail ~__LOC__ line =
      Test.fail
        ~__LOC__
        "[parse_p2p_stat] Could not parse line:\n\
         %s\n\
        \ when parsing client output:\n\
         %s"
        line
        client_output
    in
    let lines = String.(split_on_char '\n' (trim client_output)) in
    let _prefix, lines = span (( <> ) "GLOBAL STATS") lines in
    let _global_stats, lines = span (( <> ) "CONNECTIONS") lines in
    let connections, lines = span (( <> ) "KNOWN PEERS") lines in
    let known_peers, known_points = span (( <> ) "KNOWN POINTS") lines in
    let connections =
      (* Example: *)
      (* ↘ idscnVnp4ZgHbxBem9ZkaGtmVDdPt3 127.0.0.1:16392 (TEZOS.2 (p2p: 1))  *\) *)
      List.map
        (fun line ->
          match line =~* rex "(id\\w+)" with
          | Some peer_id -> Peer_id peer_id
          | None -> fail ~__LOC__ line)
        (List.tl connections)
    in
    let known_peers =
      (* Example: *)
      (* ⚏  1 idtn1bQKkQvzgPH5zbD86Bi3eTgQhB ↗ 0 B (0 B/s) ↘ 0 B (0 B/s)   *\) *)
      List.map
        (fun line ->
          match line =~** rex "(⚏|⚌).* (id\\w+)" with
          | Some (connection, peer_id) ->
              {id = Peer_id peer_id; connected = connection = "⚌"}
          | None -> fail ~__LOC__ line)
        (List.tl known_peers)
    in
    let known_points =
      (* Example: *)
      (* ⚏  127.0.0.1:16388 (last seen: idtn1bQKkQvzgPH5zbD86Bi3eTgQhB 2023-01-16T13:23:08.499-00:00) *)
      List.map
        (fun line ->
          match line =~*** rex "(⚏|⚌)\\s+(\\S+:\\S+).* (id\\w+)" with
          | Some (connection, point_id, peer_id) ->
              {
                id = point_id_of_string point_id;
                peer = {connected = connection = "⚌"; id = Peer_id peer_id};
              }
          | None -> fail ~__LOC__ line)
        (List.tl known_points)
    in
    {connections; known_peers; known_points}

  (* This test sets up a clique. It compares the output of
     [octez-admin-client p2p stat] with queries on the node RPC. *)
  let register () =
    Test.register
      ~__FILE__
      ~title:"Test [octez-admin-client p2p stat]"
      ~tags:["p2p"; "connections"; "p2p_stat"]
    @@ fun () ->
    let num_nodes = 5 in
    Log.info "Start a clique of %d nodes" num_nodes ;
    let nodes = Cluster.create num_nodes [] in
    Cluster.clique nodes ;
    let* () = Cluster.start ~wait_connections:true nodes in
    Log.info "Compare RPC information with [octez-admin-client p2p stat]" ;
    let* () =
      iter_p nodes @@ fun node ->
      let* client = Client.init ~endpoint:(Node node) () in
      let* output = Client.Admin.p2p_stat client in
      let p2p_stat = parse_p2p_stat output in
      let* rpc_points =
        let* points = RPC.(call node @@ get_network_points) in
        return
          (List.map
             (fun (point_id_s, meta) ->
               {
                 id = point_id_of_string point_id_s;
                 peer =
                   {
                     id = Peer_id JSON.(meta |-> "p2p_peer_id" |> as_string);
                     connected =
                       JSON.(meta |-> "state" |-> "event_kind" |> as_string)
                       = "running";
                   };
               })
             points)
      in
      let* rpc_peers =
        let* peers = RPC.(call node @@ get_network_peers) in
        return
          (List.map
             (fun (peer_id_s, meta) ->
               {
                 id = Peer_id peer_id_s;
                 connected = JSON.(meta |-> "state" |> as_string) = "running";
               })
             peers)
      in
      Check.(
        (List.sort compare_known_point rpc_points
        = List.sort compare_known_point p2p_stat.known_points)
          (list known_point_typ)
          ~__LOC__
          ~error_msg:"Expected %R, got %L" ;
        (List.sort compare_known_peer rpc_peers
        = List.sort compare_known_peer p2p_stat.known_peers)
          (list known_peer_typ)
          ~__LOC__
          ~error_msg:"Expected %R, got %L") ;
      unit
    in
    unit
end

let register_protocol_independent () =
  Maintenance.tests () ;
  ACL.tests () ;
  test_advertised_port () ;
  Known_Points_GC.tests () ;
  Connect_handler.tests () ;
  trusted_ring () ;
  expected_peer_id () ;
  P2p_stat.register ()

let register ~(protocols : Protocol.t list) =
  check_peer_option protocols ;
  test_one_connection protocols
