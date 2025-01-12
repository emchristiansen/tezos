(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
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

module Unit_test : sig
  (**
   * Example: [spec "Dac_pages_encoding.ml" Test_dac_pages_encoding.tests]
   * Unit tests needs tag in log (like "[UNIT] some test description here...")
   * This function handles such meta data *)
  val spec :
    string ->
    unit Alcotest_lwt.test_case list ->
    string * unit Alcotest_lwt.test_case list

  (** Tests with description string without [Unit] are skipped *)
  val _skip :
    string ->
    unit Alcotest_lwt.test_case list ->
    string * unit Alcotest_lwt.test_case list
end = struct
  let spec unit_name test_cases = ("[Unit] " ^ unit_name, test_cases)

  let _skip unit_name test_cases = ("[SKIPPED] " ^ unit_name, test_cases)
end

let () =
  Alcotest_lwt.run
    "protocol > unit"
    [
      Unit_test.spec "Dac_pages_encoding.ml" Test_dac_pages_encoding.tests;
      Unit_test.spec
        "Dac_plugin_registration.ml"
        Test_dac_plugin_registration.tests;
    ]
  |> Lwt_main.run
