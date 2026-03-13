

open Dream
open Kiosk_project
open Bigarray
(*in ocaml the pointer arithmetic is our own problem - all pointers are just Int64*)
(*this is what holds the reference to the Bigarray*)
let shared_mem_holder = ref None
(*for fnv hashing of email*)
let fnv_offset_basis = Int32.of_int 0x811C9DC5
let fnv_prime = Int32.of_int 0x01000193
let size = 2147483648 (* 2^31*)
let num_slots = 8388607 + 1 (* each UserSlot is 192, so the highest power of 2 we can use for num slots is 2^23*)
(*the reason we want a power of two for num_slots is to make the calculation of hash % num_slots simple (bitwise)*)

let hash (email : string) = (*32 bit fnv non cryptographic hash*)
  let fin = String.length email in
  let rec hash_help i h = 
    match i with 
      | x when x = fin -> h
      |  _ -> 
        hash_help (i+1) @@ Int32.mul fnv_prime @@ Int32.logxor h (Int32.of_int (Char.code email.[i])) in
  let h = hash_help 0 fnv_offset_basis in (*this hash could be negative from overflow. it will mathe the integer rust sees however, by 2^32 congruence*)
  h

let find_user_index ba email = (*this uses linear probing to find the first available slot at hash % num_slots*)
  let target_hash = hash email in
  let rec find_user_helper trial_index =
    let base = trial_index * 192 in
    match ba.{base} with 
    |0 -> None
    |1 -> find_user_helper (trial_index + 1)
    |_ ->
    let hash_matches = 
        ba.{base + 8} = Int32.(to_int (logand target_hash 0xFFl)) &&
        ba.{base + 9} = Int32.(to_int (logand (shift_right_logical target_hash 8) 0xFFl)) &&
        ba.{base + 10} = Int32.(to_int (logand (shift_right_logical target_hash 16) 0xFFl)) &&
        ba.{base + 11} = Int32.(to_int (logand (shift_right_logical target_hash 24) 0xFFl)) 
      in
      match hash_matches with 
      |true -> Some trial_index
      |false -> find_user_helper (trial_index + 1) in
  find_user_helper @@ (Int32.to_int (Int32.logand target_hash @@ Int32.of_int 8388607)) (*the aforementioned bitwise mod*)

let delete_user_unsafe ba index =
  ba.{index*192}<- 1; (*to save time all we need to do is mark the slot as a tombstone*)
  ba.{index*192 + 1}<- ba.{index*192 + 1}+1; (*and increment the version*)
  ()


let delete_user ba email = match (find_user_index ba email) with 
|  Some i -> delete_user_unsafe ba i; 
  Ok  ("deleted user with email " ^ email ^ " at index " ^ (string_of_int i))
| None -> Error ("could not find existing user with email"^ email)  

let insert_user_unsafe index hashed_email ba age email name =
  ba.{index * 192} <- 2;(*status*)
  ba.{(index * 192) + 1} <- ba.{(index * 192) + 1}+1;(*increment version*)
  (*since we;re working with 8 bit slots, writing 32 bit numbers is fiddly:*)
  ba.{(index* 192)+ 8} <- Int32.(to_int (logand hashed_email 0xFFl));
  ba.{(index* 192)+ 9} <- Int32.(to_int (logand (shift_right_logical hashed_email 8) 0xFFl));
  ba.{(index* 192)+ 10} <- Int32.(to_int (logand (shift_right_logical hashed_email 16) 0xFFl));
  ba.{(index* 192)+ 11} <- Int32.(to_int (logand (shift_right_logical hashed_email 24) 0xFFl));
  ba.{(index*192) + 16} <- age;
  let fin = String.length email in
  for i = 0 to (fin - 1) do 
    ba.{(index* 192) + 17 + i} <- (Char.code email.[i]);
  done;
  if fin < 64 then
    ba.{(index * 192) + 17 + fin} <- 0;(*add null terminator*)
  let fin = (String.length name) in
  for i = 0 to (fin - 1) do 
    ba.{(index* 192) + 81 + i} <- (Char.code name.[i]);
  done; 
  if fin < 64 then
    ba.{(index * 192) + 81 + fin} <- 0;(*add null terminator*)
  ()


  (*the rough idea is only tombstones or empty slots can be written to, otherwise try the next slot.*)
let insert_user_hashed hashed_email ba age email name =
  let rec insert_user_hashed_helper trial_index hashed_email ba age email name  =
  match ba.{trial_index * 192} with 
   |0|1  ->
       insert_user_unsafe trial_index hashed_email ba age email name;
  | _ -> insert_user_hashed_helper (trial_index + 1) hashed_email ba age email name in
  insert_user_hashed_helper (Int32.to_int (Int32.logand hashed_email @@ Int32.of_int 8388607)) hashed_email ba age email name;
  ()
  
let insert_or_update_user ba age email name = 
match find_user_index ba email with
  |Some i -> insert_user_unsafe i (hash email) ba age email name; 
  |None -> insert_user_hashed (hash email) ba age email name;
  ()

let get_user_name ba index =
  (*
this commented code would make sort of a seqlock with regards to the sqlite db. 
  while ba.{(index * 192)+ 1} <> ba.{(index * 192)+ 2} do
    () 
  done;
  *)
  let start_offset = (index * 192) + 81 in
  let max_len = 64 in
  let rec find_len i =
    if i >= max_len || ba.{start_offset + i} = 0 then 
      i
    else 
      find_len (i + 1)
  in
  let len = find_len 0 in
  String.init len (fun i -> 
    Char.chr ba.{start_offset + i}
  )

let get_user_age ba index =
  (*
this commented code would make sort of a seqlock with regards to the sqlite db. 
reduces performance a tad.
  while ba.{(index * 192)+ 1} <> ba.{(index * 192)+ 2} do
    () 
  done;
  *)
  ba.{index * 192 + 16}

  (*the main entry point for the shared memory and rust background worker*) 
let run_shared_memory () =
  let path_write = "/dev/shm/hft_kiosk" in
  
  (* 1. Create/Open the shared memory file *)
  let fd= Unix.openfile path_write [Unix.O_RDWR; Unix.O_CREAT] 0o666 in
  
  (* 2. Using a Bigarray of 8-bit ints. 
     we need to manually handle pointer arithmetic in ocaml, hence the magic numbers "192" etc *)
  let ba = array1_of_genarray (Unix.map_file fd int8_unsigned c_layout true [|size|]) in
  (* 3. put it in the global variable - not very functional of me :( *)
  shared_mem_holder := Some ba; 
  (*4. spawn_worker is the rust function which reads the Bigarray and saves to/deletes from sqlite*)
    spawn_worker ba;

  Printf.printf "Rust worker spawned. Starting benchmark...\n%!";

  ()


  (*the rest of this is htmx stuff. the function let () = is the entrypoint of the app*)

let add_user_form = {| 
<div id="add_user" class="mt-3 p-4 border rounded bg-orange-50 shadow-sm max-w-md">
  <form hx-post="/update_or_create_user" hx-target="#add_user_messages" class="flex flex-col gap-4">

    <div class="flex flex-col">
      <label for="email" class="mb-1 font-semibold text-gray-700">Email</label>
      <input type="email" id="email" name="email" placeholder="user@example.com"
             class="border p-2 rounded focus:outline-none focus:ring-2 focus:ring-blue-400"/>
    </div>

    <div class="flex flex-col">
      <label for="name" class="mb-1 font-semibold text-gray-700">Name</label>
      <input type="text" id="name" name="name" placeholder="Full Name"
             class="border p-2 rounded focus:outline-none focus:ring-2 focus:ring-blue-400"/>
    </div>

    <div class="flex flex-col">
      <label for="age" class="mb-1 font-semibold text-gray-700">Age</label>
      <input type="number" id="age" name="age" placeholder="20" min="1" max="100"
             class="border p-2 rounded focus:outline-none focus:ring-2 focus:ring-blue-400"/>
    </div>

    <button type="submit"
            class="bg-green-500 hover:bg-green-600 text-white font-semibold px-4 py-2 rounded shadow">
      Save
    </button>

  </form>
<div id="add_user_messages" class="mt-2 text-green-600 font-semibold"></div>
</div>

|}



let home_handler _req = html @@
    Printf.sprintf {|
      <html>
        <head>
    <script src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js" integrity="sha384-/TgkGk7p307TH7EXJDuUlgG3Ce1UVolAOFopFekQkkXihi5u/6OCvVKyz1W+idaz" crossorigin="anonymous"></script>
    <script src="https://cdn.jsdelivr.net/npm/htmx-ext-sse@2.2.4" integrity="sha384-A986SAtodyH8eg8x8irJnYUk7i9inVQqYigD6qZ9evobksGNIXfeFvDwLSHcp31N" crossorigin="anonymous"></script>
 <script src="https://cdn.tailwindcss.com"></script>
<style>
    .btn-purple {
      background-color: #9b30ff; /* bright purple */
      color: white;
      border: none;
      padding: 10px 20px;
      font-size: 16px;
      cursor: pointer;
      border-radius: 5px;
    }
    .btn-purple:hover {
      background-color: #7d1edb;
    }
    input[type="number"] {
      width: 80px;
      padding: 5px;
      font-size: 16px;
      margin-right: 10px;
    }
    .success-message {
      background-color: #d4edda; /* soft green */
      border: 1px solid #c3e6cb; /* darker green border */
      color: #155724; /* dark green text */
      padding: 20px 30px;
      border-radius: 8px;
      font-family: Arial, sans-serif;
      font-size: 16px;
      box-shadow: 0 4px 6px rgba(0,0,0,0.1);
      max-width: 500px;
      margin: 20px auto;
      text-align: center;
    }

    .success-message strong {
      font-weight: bold;
    }
  </style>
</head>
<body hx-ext="sse" class="bg-gray-900 text-red-800 p-6">


<h1 class="text-4xl font-bold text-yellow-400 mb-4">
HIGH FREQUENCY CRUD
</h1>


  <form id="generateForm">
    <input type="number" name="count" value="1" min="1" />
    <button 
      class="btn-purple"
      hx-get="/generate_users"
      hx-target="#usersContainer"
      hx-include="#generateForm"
    >
      Generate Users
    </button>
  </form>
<div id="usersContainer" hx-target="this"></div>
<hr class="border-orange-500 border-2 my-6"/>

<h2 class="text-4xl font-bold text-yellow-400 mb-4">
Add User
</h2>
%s
<hr class="border-orange-500 border-2 my-6"/>

<h2 class="text-4xl font-bold text-yellow-400 mb-4">
  Live Monitoring
</h2>

<form hx-post="/search" 
      hx-target="#search-results" 
      hx-swap="beforeend" 
      hx-on::after-request="this.reset()"> <input type="text" 
           name="email" 
           placeholder="Search for email and hit enter" 
           required>
  <button type="submit" class="bg-green-500 text-white px-4 py-2 rounded hover:bg-green-600 mr-2">add user to monitoring</button>
<div id="search-results">
    </div>
</form>
        </body>
      </html>
    |} add_user_form

let clean_name s = 
  String.map (fun c -> if c = '@' || c = '.' then '_' else c) s

let replacement_sse_stream email = 
    let id = clean_name email in
html (Printf.sprintf 
    {|<div id="sse-container-%s" class="p-2 border">
    <button class="bg-gray-500 text-white p-1 rounded"
          hx-on:click="this.closest('#sse-container-%s').remove()">
    remove from screen

  </button>
<button
  hx-get="/delete_user?email=%s"

  class="bg-red-500 hover:bg-red-600 text-white font-bold px-3 py-1 rounded shadow">
  delete
</button>
    <button
      onclick="document.getElementById('edit-%s').classList.toggle('hidden')"
      class="bg-yellow-400 hover:bg-yellow-500 text-black font-semibold px-3 py-1 rounded shadow">
      edit
    </button>
        <div hx-ext="sse" 
             sse-connect="/monitor_user?email=%s"> <div id="monitor-%s" sse-swap="%s" hx-target="#monitor-%s" hx-swap="innerhtml">
                monitoring: %s
             </div>
        </div>
  <div id="edit-%s" class="hidden mt-3 p-3 border rounded bg-gray-50">
    <form hx-post="/update_or_create_user"
          class="flex gap-2 items-center">

      <input type="hidden" name="email" value="%s"/>

      <input type="text"
             name="name"
             placeholder="new name"
             class="border p-1 rounded"/>


      <input type="number"
             name="age"
             placeholder="20"
            min="1" max="100"
             class="border p-1 rounded"/>

      <button class="bg-blue-500 hover:bg-blue-600 text-white px-3 py-1 rounded">
        save
      </button>

    </form>
  </div>
      </div>|} 
    id id email id email id id id email id email)

let sse_clean_html html =
  String.split_on_char '\n' html
  |> List.map String.trim
  |> String.concat " "

  (*this is the sse function. when a user is added to the view, this function is subscribed to per user div*)
let monitor_user_loop _param stream =
    let rec loop () =
      let%lwt () = Lwt_unix.sleep 0.005 in
      let ba = match !shared_mem_holder with  (*our global variable ba*)
        | Some b -> b
        | None -> failwith "ba was not set"
      in
      match find_user_index ba _param with
      | None -> 
      let content = sse_clean_html (Printf.sprintf  
    {|
    <div>
    User not found: %s
    </div>
      |} _param)in
      let message = Printf.sprintf "event: %s\ndata: %s\n\n" (clean_name _param) content in
      let%lwt () = Dream.write stream (message) in
      let%lwt () = Dream.flush stream in
      loop () 

      |Some index -> 
      let content = sse_clean_html (Printf.sprintf  
    {|
<div class="flex items-center justify-between bg-yellow-300 text-gray-900 font-semibold px-4 py-3 rounded-lg shadow-md">
  <span class="text-blue-700">Monitoring: %s</span>
  <span class="text-purple-700">Name: %s</span>
  <span class="text-red-600">Age: %d</span>
</div>
      |}
     _param (get_user_name ba index) (get_user_age ba index)) in
      let message = Printf.sprintf "event: %s\ndata: %s\n\n" (clean_name _param) content in
      let%lwt () = Dream.write stream (message) in
      let%lwt () = Dream.flush stream in
      loop () 
    in
    loop ()

let monitor_user req =
  let _param = match Dream.query req "email" with
    | None -> "none"
    | Some message ->
      message in
  let headers = [
    "Content-Type", "text/event-stream";
    "Cache-Control", "no-cache"
  ] in
  
  Dream.stream ~headers (monitor_user_loop _param)



type email_req = { email : string; }
let email_req =
    let open Dream_html.Form in
    let+ email = required string "email" in
    { email;  }

let search_handler  req =
  match%lwt Dream_html.form ~csrf:false email_req req with
| `Ok { email;  } -> replacement_sse_stream email 
  | `Invalid _ ->  
      html {|<div id="result">invalid fields</div>|}
  | `Missing_token _ -> 
      html {|<div id="result">error: missing csrf token</div>|}
  | `Wrong_session _ -> 
      html {|<div id="result">error: session mismatch</div>|}
  | `Wrong_method -> 
      html {|<div id="result">error: use POST</div>|}
  | _ -> 
      html {|<div id="result">generic error</div>|}


type new_user_req = { email : string; name: string; age: int}
let  new_user_req =
    let open Dream_html.Form in
    let+ email = required string "email"
    and+ name = required string "name"
and+ age = required int "age" in
    { email; name; age }

let update_or_create_handler  req =
let ba = match !shared_mem_holder with 
  | Some b -> b
  | None -> failwith "ba was not set" in
  match%lwt Dream_html.form ~csrf:false new_user_req req with
  | `Ok { email; name; age  } -> 
  insert_or_update_user ba age email name;
  html ("success")
  | `Invalid _ ->  
      html {|<div id="result">invalid fields</div>|}
  | `Missing_token _ -> 
      html {|<div id="result">error: missing csrf token</div>|}
  | `Wrong_session _ -> 
      html {|<div id="result">error: session mismatch</div>|}
  | `Wrong_method -> 
      html {|<div id="result">error: use POST</div>|}
  | _ -> 
      html {|<div id="result">generic error</div>|}
     


     


let delete_user_handler req =
let ba = match !shared_mem_holder with 
  | Some b -> b
  | None -> failwith "ba was not set" in
  let _param = match Dream.query req "email" with
    | None -> "none"
    | Some message ->
      message in
  let res = delete_user ba _param in
match res with 
  | Ok _ -> 
      Dream.html ""
  | Error str -> 
      print_endline str; 
      Dream.html ~status:`Internal_Server_Error ("Error deleting user"^ str)

let rec generate_users ba i =
  match i with
  | x when x < 1 -> ()
  | x ->
      let str = string_of_int x in
      insert_or_update_user ba x (str ^ "@" ^ str ^".com") ("mr: "^ str);
  generate_users ba (i-1)   

let generate_users_handler req =
let ba = match !shared_mem_holder with 
  | Some b -> b
  | None -> failwith "ba was not set" in
  match Dream.query req "count" with
    | None -> html "no count provided"
    | Some count ->
  let start_time = Unix.gettimeofday () in
        generate_users ba (int_of_string count);
let end_time = Unix.gettimeofday () in
  let duration_microseconds = (end_time -. start_time) *. 1_000. in
        html @@ Printf.sprintf 
        {|  <div class="success-message">
    Generated <strong>%d</strong> users in <strong>%f</strong> milliseconds.<br/>
    Users are of the form <code>int@int.com</code>
  </div>|} (int_of_string count) duration_microseconds

let () =
  run_shared_memory (); 
  print_endline "starting dream server";
let ba = match !shared_mem_holder with 
  | Some b -> b
  | None -> failwith "ba was not set"
in
insert_or_update_user ba 3 "hrldrobson@gmail.com" "Harold Robson";
  Dream.run ~interface:"0.0.0.0" ~port:8080
  @@ Dream.logger
  @@ Dream.router [
       Dream.get "/" home_handler;
       Dream.post "/search" search_handler; 
       Dream.get "/monitor_user" monitor_user;
       Dream.get "/delete_user" delete_user_handler;
       Dream.post "/update_or_create_user" update_or_create_handler;
       Dream.get "/generate_users" generate_users_handler;
     ]
