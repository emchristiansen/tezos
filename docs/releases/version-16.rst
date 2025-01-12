Version 16.0~rc2
================

Version 16.0 contains a new version (V8) of the protocol environment,
which is the set of functions that a protocol can call. This new version is used by protocol :doc:`Mumbai<../protocols/016_mumbai>`,
which is a proposal for the successor of Lima. This release also
contains Mumbai itself as well as its daemons.

New executables have been introduced for Smart Rollups.
This includes ``octez-smart-rollup-node-PtMumbai``, ``octez-smart-rollup-client-PtMumbai`` and ``octez-smart-rollup-wasm-debugger``.
They can be used with the ``Mumbai`` protocol.

.. warning::

   Octez version 15.0 renamed all executables. The ``tezos-`` prefix
   has been replaced by ``octez-`` and protocol numbers have been removed.
   However, the old naming convention was still available via symbolic links.
   Starting from version 16.0, the symbolic links from old names to new names are no longer created when compiling from source.
   The old names are no longer supported.

Octez v16 uses a new data format for the storage layer, introduced in order to reduce disk usage during context pruning.
There is no particular action needed to upgrade the storage, as it is done automatically when restarting the node.
However, during the next 6 cycles after upgrading to Octez v16,
the total disk usage will be slightly higher due to the automatic storage migration.
This will result in an overhead of a few gigabytes (around 10GB) of disk usage during a 6 cycles period.
To avoid this overhead, you can import a fresh snapshot.

The second release candidate (16.0~rc2) fixes an issue where old contexts (v13 or older) would be corrupted at cycle switch.
The docker images no longer cause a "permission denied" error on ``entrypoint.sh``, hence can now be used properly.
This new release candidate also includes an improvement of the ``octez-smart-rollup-node`` that drastically reduces disk consumption.

Update Instructions
-------------------

To update from sources::

  git fetch
  git checkout v16.0-rc2
  make build-deps
  eval $(opam env)
  make

If you are using Docker instead, use the ``v16.0-rc2`` Docker images of Octez.

If you are installing Octez using Opam, note that the minimal required
OCaml version is now 4.14.1. This means that you might need to create a
new switch with ``opam switch create 4.14.1`` before you run ``opam install tezos``.


Changelog
---------

- `Version 16.0~rc2 <../CHANGES.html#version-16-0-rc2>`_
- `Version 16.0~rc1 <../CHANGES.html#version-16-0-rc1>`_
