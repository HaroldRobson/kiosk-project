# High Frequency CRUD (Kiosk)

A hybrid **OCaml-Rust** system designed for ultra-low latency user management. This project bypasses traditional JSON/REST bottlenecks by using **Shared Memory (/dev/shm)** as the primary data plane, allowing an OCaml web server to communicate with a Rust persistence worker at memory-bus speeds.

## System Architecture

The system is split into a **Hot Path** (performance-critical) and a **Cold Path** (durability-critical).

* **Hot Path (OCaml):** A Dream-based web server that performs non-cryptographic FNV-1a hashing and writes directly into a 2GB raw byte buffer (`Bigarray`). The FNV hashing is to essentially turn it into a hash map (with linear probing), with the email as key. .
* **Shared Bigarray:** A shared memory file located at `/dev/shm/hft_kiosk`.
* **Cold Path (Rust):** A background worker that scans the memory buffer for version mismatches and syncs changes to a SQLite database using `sqlx`.
In order to produce just one binary, I used ocaml-rs to make the Cold Path accessible from ocaml. 

---

## Memory Layout & Concurrency

The system treats memory as a flat array of **8,388,608 slots**, each exactly **192 bytes** wide. To ensure cache alignment and prevent "False Sharing," the Rust struct is decorated with `#[repr(C, align(64))]`.
The "pointer arithmetic" was not too hard, but de/recoding say a 32 bit integer or even worse a variable length string was. Rust has pretty good ergonomics for this (read/write_volatile in unsafe rust). Ocaml doesn't.

### The `UserSlot` Structure

| Offset | Field | Size | Description |
| --- | --- | --- | --- |
| 0 | `status` | 1B | 0=Empty, 1=Tombstone, 2=Active |
| 1 | `version` | 1B | Incremented by OCaml on every write |
| 2 | `last_synced` | 1B | Updated by Rust after SQL commit |
| 8-15 | `hash` | 8B | 64-bit FNV Hash (aligned) |
| 16 | `age` | 1B | User age |
| 17-80 | `email` | 64B | Null-terminated string |
| 81-144 | `name` | 64B | Null-terminated string |
![Diagram](Diagram.jpg)
### Version-Based Syncing

I avoided expensive Mutexes. In fact, blocking is not really an issue at all in this system. Instead, we use a **Version/Last_Synced** protocol:

1. **OCaml** writes data and increments `version`.
2. **Rust** constantly polls memory. If `version != last_synced`, Rust kicks off a SQL update.
3. Once the DB confirms, **Rust** sets `last_synced = version`.
4. If Ocaml tries to read a UserSlot which is out of sync, it blocks. I uncommented the loops which do this for the sake of performance. 
This is somewhat similar to a Seqlock around the database.
Do note that there is nothing (beyond probability) to stop the ui displaying data `whilst` it is being modified. The UI refreshes every 5ms from sse so this is not a huge issue. 
---

## Key Performance Features

### 1. FNV-1a Hashing & Bitwise Masking

OCaml implements a 32-bit FNV-1a hash. To find a slot in $O(1)$ time, we use a power-of-two table size ($2^{23}$ slots). This allows us to replace the expensive modulo operator with a bitwise `AND`:

```ocaml
(* OCaml bitwise mod trick *)
Int32.logand hashed_email (Int32.of_int 8388607)

```

### 2. Linear Probing with Tombstones

The system uses **Open Addressing**. If a hash collision occurs, `insert_user_hashed` probes the next sequential slot. I used a `status` of `1` (Tombstone) to ensure that a deleted user doesn't break the search chain for users hashed to the same index.

### 3. SSE Live Monitoring

The UI uses **HTMX** and **Server-Sent Events (SSE)**. The `monitor_user_loop` in OCaml polls the shared memory every **5ms** to provide a real-time "update" of user data without ever hitting the database - just from the memory buffer.

---

## Tech Stack

* **Frontend:** HTMX, Tailwind CSS (delivered via OCaml Dream).
* **Backend (Logic):** OCaml, `Lwt` for non-blocking I/O, `Bigarray` for shared memory access.
* **Backend (Persistence):** Rust, `Tokio` (multi-threaded runtime), `sqlx` (asynchronous SQLite).
* **Communication:** `ocaml-rs` for high-performance FFI (Foreign Function Interface).

---

## Benchmarks

> **Environment:** Linux `/dev/shm` (RAM-backed storage)
> **Operation:** 100,000 User Creations (Hashing + String Formatting + Memory Write)
> **Result:** ~95 milliseconds. So about 1 microsecond per user.
> Maximum number of users: 388608
> Rust time to scan 2gb Buffer: ~425ms

---

## 🚀 How to Run

1. **Create Database**
```bash
sqlite3 data.db
>>CREATE TABLE useless(name INTEGER);

```
The "useless" table is just to make the data persist. users is created by Rust on init. 


2. **Build the Rust Worker:**
Compile the Rust library to a shared object linked by OCaml.
3. **Launch Binary (only on linux X86):**
```bash
./_build/default/test/test.exe


```
3b. Otherwise install Rust and Ocaml (with dune) and run:
```bash
dune build
./_build/default/test/test.exe


```

4. **Access UI:**
Navigate to `http://localhost:8080`.

---

> **Note on Safety:** This project uses `unsafe` blocks in Rust for `volatile_read` and `volatile_write` to ensure the compiler doesn't optimize away memory reads that are being modified externally by the OCaml process.

---
