use sqlx::*;
use std::str::FromStr;
#[repr(C, align(64))] // use 64 bit alignment to reduce cache misses
#[derive(Debug, Eq, PartialEq, Clone, Copy, sqlx::FromRow)]
struct UserSlot {
    status: u8,  // 0-empty |1-tombstone, |2-active, (tombstone is needed for linear probing)
    version: u8, // incremented when user updates in ocaml
    last_synced: u8, // incremented by rust
    hash: u64,   // from the FNV hashing function in ocaml
    age: u8,     // no one's older than 255
    email: [u8; 64],
    name: [u8; 64],
}

#[derive(Debug, Eq, PartialEq)]
enum UserSlotType {
    Empty,
    Tombstone(UserSlot),
    Active(UserSlot),
}

impl UserSlot {
    // helper functions for getting users out of the buffer and into the sqlite db
    unsafe fn from_buffer(ptr: *mut UserSlot, index: usize) -> UserSlotType {
        let raw_ptr: *mut u64 = ptr.add(index) as *mut u64;
        match std::ptr::read_volatile(raw_ptr.add(0)) as u8 {
            0 => UserSlotType::Empty,
            1 => UserSlotType::Tombstone(std::ptr::read_volatile(raw_ptr as *const Self)),
            _ => UserSlotType::Active(std::ptr::read_volatile(raw_ptr as *const Self)),
        }
    }

    unsafe fn to_buffer(self, ptr: *mut UserSlot, index: usize) {
        std::ptr::write_volatile(ptr.add(index), self)
    }

    // remove duplication, keeping most recent
    // vesrion
    fn keep_newest(mut users: Vec<Self>) -> Vec<Self> {
        users.sort_by(|a, b| a.hash.cmp(&b.hash).then_with(|| b.version.cmp(&a.version)));
        users.dedup_by(|a, b| if a.hash == b.hash { true } else { false });
        users
    }

    async fn delete_from_db(mut users: Vec<Self>, db: &sqlx::Pool<sqlx::Sqlite>) {
        if users.is_empty() {
            return;
        }
        users = UserSlot::keep_newest(users);
        let mut query_builder = QueryBuilder::new("DELETE FROM users WHERE hash in (");
        let mut separated = query_builder.separated(", ");
        for user in users {
            separated.push_bind(user.hash as i64);
        }
        separated.push_unseparated(")");
        let query = query_builder.build();
        query.execute(db).await.unwrap();
    }

    async fn save_to_db(mut users: Vec<UserSlot>, db: &sqlx::Pool<sqlx::Sqlite>) {
        if users.is_empty() {
            return;
        }
        users = UserSlot::keep_newest(users);
        let mut query_builder = QueryBuilder::new(
            "INSERT OR REPLACE INTO users(status, version, hash, age, email, name) ",
        );
        query_builder.push_values(users.into_iter(), |mut b, user| {
            let email_str = String::from_utf8_lossy(&user.email)
                .trim_matches(char::from(0))
                .to_string();
            let name_str = String::from_utf8_lossy(&user.name)
                .trim_matches(char::from(0))
                .to_string();
            b.push_bind(user.status)
                .push_bind(user.version)
                .push_bind(user.hash as i64)
                .push_bind(user.age)
                // Convert fixed [u8; 64] to String, trimming null bytes
                .push_bind(email_str)
                .push_bind(name_str);
        });
        let mut query = query_builder.build();
        query.execute(db).await.unwrap();
    }
}

fn to_fixed_64(dynamic_data: &[u8]) -> [u8; 64] {
    //helper function for byte array conversion
    let mut fixed = [0u8; 64];
    let len = dynamic_data.len().min(64);
    fixed[..len].copy_from_slice(&dynamic_data[..len]);
    fixed
}

// this is the big function ocaml calls when launched
// ba is big array in shared memory
#[ocaml::func]
#[ocaml::sig("(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> unit")]
pub unsafe fn spawn_worker(mut ba: ocaml::bigarray::Array1<i64>) {
    user_slot_mem_layout();
    let slice = ba.data_mut();
    let raw_ptr: *mut i64 = slice.as_mut_ptr();
    let addr = raw_ptr as usize;
    use sqlx::sqlite::*;

    println!("spawn_worker started");
    std::thread::spawn(move || {
        let ptr = addr as *mut UserSlot;

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to create Tokio runtime");
        rt.block_on(async {
            let conn = SqlitePool::connect_with(
                SqliteConnectOptions::from_str("sqlite://data.db").unwrap(),
            )
            .await
            .unwrap();

            sqlx::query(
                "
                    CREATE TABLE IF NOT EXISTS users(
                    status INTEGER,
                    version INTEGER,
                    hash INTEGER PRIMARY KEY,
                    age INTEGER,
                    email TEXT,
                    name TEXT
                    );",
            )
            .execute(&conn)
            .await
            .unwrap();

            loop {
                let mut users_to_add = vec![];
                let mut users_to_delete = vec![];
                let start_scan = std::time::Instant::now();
                for i in 0..8388608 {
                    match UserSlot::from_buffer(ptr, i) {
                        UserSlotType::Active(userslot) => {
                            if userslot.version != userslot.last_synced {
                                users_to_add.push(userslot); // this also updates users
                                unsafe {
                                    //replace last_synced with version
                                    let index = ptr.add(i) as *mut u8;
                                    std::ptr::write_volatile(index.add(2), userslot.version);
                                }
                            }
                        }
                        UserSlotType::Tombstone(userslot) => {
                            if userslot.version != userslot.last_synced {
                                users_to_delete.push(userslot);
                                unsafe {
                                    let index = ptr.add(i) as *mut u8;
                                    std::ptr::write_volatile(index.add(2), userslot.version);
                                }
                            }
                        }
                        UserSlotType::Empty => {}
                    }
                }
                let scan_duration = start_scan.elapsed();
                println!("duration to scan 2gb buffer: {:?}", scan_duration);
                UserSlot::save_to_db(users_to_add, &conn).await;
                UserSlot::delete_from_db(users_to_delete, &conn).await;
            }
        });
    });
}

fn user_slot_mem_layout() {
    use memoffset;
    println!("UserSlotSize: {:}", std::mem::size_of::<UserSlot>());
    println!("status: {:}", memoffset::offset_of!(UserSlot, status));
    println!("version: {:}", memoffset::offset_of!(UserSlot, version));
    println!(
        "last_synced: {:}",
        memoffset::offset_of!(UserSlot, last_synced)
    );
    println!("hash: {:}", memoffset::offset_of!(UserSlot, hash));
    println!("age: {:}", memoffset::offset_of!(UserSlot, age));
    println!("email: {:}", memoffset::offset_of!(UserSlot, email));
    println!("name: {:}", memoffset::offset_of!(UserSlot, name));
}

unsafe fn user_slot_test(ptr: *mut UserSlot) {
    let email = "meow@meow.com";
    let name = "bunting";
    let userslot = UserSlot {
        status: 2,
        version: 4,
        last_synced: 3,
        hash: 12039879,
        age: 22,
        email: to_fixed_64(email.as_bytes()),
        name: to_fixed_64(name.as_bytes()),
    };
    userslot.clone().to_buffer(ptr, 7);
    let userslot_b = UserSlot::from_buffer(ptr, 7);
    dbg!(UserSlotType::Active(userslot.clone()));
    dbg!(&userslot_b);
    assert_eq!(UserSlotType::Active(userslot), userslot_b);
}
