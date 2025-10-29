# 🧩 Pgpool-II Auto Resync and Reattach Enhancement

## 🔍 Overview

This repository enhances **Pgpool-II** with a new feature — **Automatic Resync and Reattach**, which automatically synchronizes a failed or lagging standby node with the primary database using `pg_rewind` and WAL replay before reattaching it to the pool.

It eliminates the need for manual intervention or external scripts after a failover or node failure, improving 💪 **availability**, 🧠 **consistency**, and ⚙️ **administrative simplicity**.

> 🧾 **Note:**  
> The sample setup provided here is for **1 Primary and 2 Standby nodes** configuration.  
> Ensure that **primary connection info (host, port, user, password)** is properly added to each standby’s `postgresql.conf` and `recovery.conf` (or `standby.signal`) so that the standby can automatically follow the promoted primary.

---

## 🚀 Existing Pgpool-II Features vs New Enhancement

| Feature | Description | Limitations |
|----------|--------------|--------------|
| **Online Recovery** | Allows data synchronization using base backup from primary to standby | Requires manual trigger via `pcp_recovery_node` or admin action |
| **Auto Failback** | Reattaches standby nodes automatically when they become available | Does **not** ensure data consistency; unsafe without manual resync |
| **🆕 Auto Resync & Reattach (New)** | Automatically runs `pg_rewind` and WAL replay before reattaching standby nodes | Fully automatic, no admin intervention, ensures data safety and consistency | Data synchronization |

---

## ⚙️ Implementation Details

### 🧩 Components Modified or Added

1. **`failover.sh`**
   - Triggered automatically during failover.  
   - Detects failed standby node and initiates `resync.sh` for synchronization.  
   - Logs operations and ensures safe detach/reattach.
   - Handles both primary and standby failover.

   🔗 **Reference:**  
   [Pgpool-II failover.sh.sample](https://github.com/pgpool/pgpool2/blob/master/src/sample/scripts/failover.sh.sample)

2. **`follow_primary.sh`**
   - Triggered when a new primary is promoted.  
   - Updates standby recovery configuration to follow the promoted primary.  

   🔗 **Reference:**  
   [Pgpool-II follow_primary.sh.sample](https://github.com/pgpool/pgpool2/blob/master/src/sample/scripts/follow_primary.sh.sample)

3. **`resync.sh` (🆕 New Script)**
   - Runs `pg_rewind` and WAL recovery automatically from the new primary.  
   - Validates connectivity, updates recovery parameters, and restarts PostgreSQL.  
   - Can be customized for multi-standby setups.

   🔗 **Reference:**  
   [Pgpool-II resync.sh.sample](https://github.com/pgpool/pgpool2/blob/master/src/sample/scripts/resync.sh.sample)

4. **`recovery_1st_stage.sh` / `recovery_2nd_stage.sh`**
   - Which bring back the failed node to online   
   - Compatible with this enhancement for optional use.
   - 
   🔗 **Reference:**  
   [Pgpool-II recovery.sh.sample](https://github.com/pgpool/pgpool2/blob/master/src/sample/scripts/recovery.sh.sample)


---

## 🧠 Architecture Diagram

```
      +----------------------------+
      |        Pgpool-II           |
      | (Failover & Connection Mgmt)|
      +-------------+--------------+
                    |
                    | Detects Failover Event
                    v
          +----------------------+
          |    failover.sh       |
          +----------------------+
                    |
                    | Triggers
                    v
          +----------------------+
          |     resync.sh        |
          | (pg_rewind + WAL     |
          |  replay & reattach)  |
          +----------------------+
                    |
                    v
          +----------------------+
          |    Standby Node      |
          | (Synced & Rejoined)  |
          +----------------------+
```

````

✨ This ensures that when a standby node goes out of sync during failover, it automatically:
1. Runs `pg_rewind` to sync files with the new primary  
2. Performs WAL replay for transaction alignment  
3. Reattaches itself safely back to Pgpool-II  

---

## 🧰 Installation & Setup Steps

### 1️⃣ Clone the Repository

```bash
git clone https://github.com/BharatDBPG/pgpool2-auto-resync.git
cd pgpool2-auto-resync
````

---

### 2️⃣ Build and Install Pgpool-II (if building from source)

If you’re building from source:

```bash
./configure
make
sudo make install
```

If Pgpool-II is already installed (via apt/yum):

```bash
sudo mkdir -p /etc/pgpool2
sudo cp scripts/*.sh /etc/pgpool2/
sudo chmod +x /etc/pgpool2/*.sh
```

---

### 3️⃣ Update `pgpool.conf`

Edit `/etc/pgpool2/pgpool.conf` and verify the following entries:

```ini
# Enable failover handling
failover_command = '/etc/pgpool2/failover.sh %d %H %P %R %r %p %D %m %M %h %P %r'

# Enable follow-primary for streaming replication setups
follow_primary_command = '/etc/pgpool2/follow_primary.sh %d %H %P %R %r %p %D %m %M %h %P %r'

# Add resync script (new)
resync_command = '/etc/pgpool2/resync.sh %d %H %P %R %r %p %D %m %M %h %P %r'

# Optional logging
log_statement = on
log_per_node_statement = on
```

📝 **Tip:** Ensure the script paths match your local system directories.

---

### 4️⃣ Configure Authentication & PostgreSQL Settings

Check PostgreSQL users:

```bash
psql -U postgres -c "\du"
```

✅ Make sure:

* The **replication user** (e.g., `repl`) exists and has replication privileges.
* The **standby nodes** have the **primary connection info** (host, port, user, password) correctly set in their configuration.

Sample entry in each standby’s `pg_hba.conf`:

```
host replication repl 192.168.0.0/24 md5
```

Then restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

---

### 5️⃣ Restart Pgpool-II and Verify Configuration

```bash
sudo systemctl restart pgpool2
sudo systemctl status pgpool2
```

If any configuration errors occur, check:

```
/var/log/pgpool/pgpool.log
```

---

### 6️⃣ Verify Auto Resync and Reattach in Action

Now test your setup 👇

1️⃣ Stop the primary node:

```bash
sudo systemctl stop postgresql
```

2️⃣ Watch Pgpool logs:

```bash
sudo journalctl -u pgpool2 -f
```

You should see something like:

```
INFO: Detected failover, node 0 marked down.
INFO: Running /etc/pgpool2/resync.sh for node 0...
INFO: pg_rewind completed successfully, reattaching standby node.
```

3️⃣ Start the stopped node again:

```bash
sudo systemctl start postgresql
```

Pgpool-II will automatically detect and reattach it 🎉

---

## 🧩 How It Works (Step-by-Step)

1. Pgpool detects node failure and triggers **`failover.sh`**
2. The failed node is identified → **`resync.sh`** is invoked automatically
3. `pg_rewind` syncs data between the new primary and failed node
4. WAL replay ensures data consistency
5. The node is reattached seamlessly to Pgpool

---


## 💡 Future Enhancements

* ⚙️ Parallel resync for multiple standby nodes
* 📡 PCP integration for monitoring
* 📊 Grafana & Prometheus metrics integration

---

 *Crafted by Vasuki Anand ✨*

````

