---
title: The Google File System
author: Angold WANG
date: 2023-05-15
slug: the-google-file-system
categories: []
tags: []
toc: true
---

## Distributed Storage

**Why do we want to distribute the storage system?**

1. **Simplify the design of the application**<br>
**Durable Storage System** means the **structure of your application would be stateless** since the remote storage holds persistent state, and thus simplifies the design of the application tremendously. 
2. **Physical reasons** (latency)
3. **High throughput across multiple servers**

### Conundrum of High-Performance

Struggle between **consistency** and **high-performance**:.<br>
**High performance** -> **Shared data across servers**<br>
**Many servers** -> **Constant faults**<br>
**fault tolerance** -> **replication**<br>
**replication** -> **potential inconsistencies**<br>
**better consistency** -> **low performance**<br>

## Consistency

**Single server model, easy to achieve strong consistency:**

![strong-consistency](/Sources/the-google-file-system/strong-consistency.jpg)

Client1 and Client2 write concurrently.  

After the writes have completed, Client3 and Client4 read. What can they see?

Answer: either 1 or 2, but both have to see the same value. This is a “strong” concurrency model.

**Replication for fault-tolerance makes strong consistency tricky to be implemented**

![consistency-with-replica](/Sources/the-google-file-system/consistency-with-replica.jpg)

Client1 and Client2 send writes to both, in parallel.

This time, both Client3 and Client4 will also see either 1 or 2, but no guarrentee that they will see the same value. 
1. The Client1 crashes before sending the write to Server 2
2. C1's and C2's write messages could arrive in different orders at the two replicas

That is not a strong consistency.

### Protocols

There are many distributed systems **protocols** between those servers/clients in real world, they are trying to make trade-offs between various aspects of the system, including **consistency**, **availability**, **latency** and **fault tolerance**.

One way to think about these trade-offs is through the lens of the [CAP theorem](https://en.wikipedia.org/wiki/CAP_theorem), which states that any distributed data store can provide only two of the following three guarantees:

{{< fig src="/Sources/the-google-file-system/cap.png" alt="CAP Theorem Venn Diagram" width="50%" title="CAP Theorem Venn Diagram" author="JamieMcCarthy" authorLink="https://commons.wikimedia.org/wiki/File:CAP_Theorem_Venn_Diagram.png" licenseLink="https://creativecommons.org/licenses/by-sa/4.0/deed.en" >}}

* **Consistency**<br>Every read receives the most recent write or an error.
* **Availability**<br>Every request receives a (non-error) response, without the guarantee that it contains the most recent write.
* **Partition tolerance**<br>The system continues to operate despite an arbitrary number of messages being dropped (or delayed) by the network between nodes. (the machine crashes are also counted in this case).

In the face of network partitions, a system must choose between **consistency** and **availability**. Some distributed systems prioritize consistency, while others prioritize availability, depending on the specific use case and requirements.

Algorithms like **Raft** and **Paxos** prioritize **strong consistency** and **fault tolerance** over **availability** during network partitions. They guarantee that all nodes in the system will have the same view of the data and will only return correct results. However, as mentioned earlier, this can lead to temporary unavailability or increased latency during certain failure scenarios.

Other distributed systems algorithms, such as **Dynamo** those based on eventual consistency or CRDTs (conflict-free replicated data types), prioritize **availability** and **low latency** over strong consistency. These systems may allow temporary inconsistencies between replicas, but they eventually converge to a consistent state as the system processes updates.


## Design Goals

1. **Scalability**:<br>GFS is designed to scale to large numbers of nodes and huge amounts of data. It achieves this by partitioning files into **chunks**, distributing those chunks across many nodes, and managing them with a **single master server**.
2. **Fault Tolerance & Reliability:**<br>Given the scale of the system, hardware failures (like disk failures or server crashes) are considered common rather than exceptional. GFS is designed to handle these failures gracefully and automatically, without significant impact on data availability or consistency.
3. **Consistency**:<br>GFS provides a **relaxed consistency** model that simplifies the file system without requiring expensive synchronization between servers. It ensures consistency through the use of **chunk version numbers** and a **lease-based mechanism for mutations.**
4. **Minimize Master Overhead:**<br>GFS tries to minimize the management overhead at the master. This is achieved by **offloading chunk mutation operations to primary replicas** and by **storing only metadata on the master**.
5. **Optimized for Large, Sequential Reads & Writes:**<br>GFS is optimized for large files that are mostly appended to (as in, written once and read many times) and then read sequentially. This is reflective of Google's workload, which involves large-scale data processing tasks.
6. **High Bandwidth**:<br>Rather than optimizing for low latency, **GFS is designed to provide high sustained bandwidth**, particularly for concurrent reads and writes across many clients.
7. **Simplicity of Design:**<br>GFS has a simple design which makes it easier to reason about and maintain. For example, all chunks are the same size (except for the last chunk of a file), and files are organized in a straightforward hierarchical directory structure.

## Control Flow

### Read Control Flow
1. **Client Request:**<br>The client sends a read request to the GFS master. The request includes the file name and the byte range that the client wants to read. 
2. **Master Response:**<br>The master responds with the location (the IP address and port) of the chunkservers that hold the relevant chunk. The master does not directly serve the data; it merely provides metadata. The chunk location information includes several replicas, and the client is free to read data from any of these replicas.
3. **Data Retrieval:**<br>The client sends a read request directly to one of the chunkservers (typically the closest one, in network terms). The request includes the chunk identifier and the byte range within the chunk that the client wants to read.
4. **Chunkserver Response:**<br>The chunkserver reads the specified byte range from the chunk and sends the data back to the client.
5. **Client Reads Data:**<br>The client receives the data and processes it as required.

### Write Control Flow

1. **Request to Master:**<br>The client requests to append data to a file. The master identifies the chunk where the data needs to be appended. If the last chunk is full, the master allocates a new chunk. It then identifies the chunkservers that hold the replicas of the chunk, and designates one of them as the primary and grand a lease to it. The master returns to the client the **chunk handle, version number, and the locations of the primary and secondary replicas.**
2. **Data Propagation:**<br>The client pushes the data to all the replicas (not just the primary). The data is forwarded along a chain of chunkservers, typically from the closest to the furthest in network distance. This way, each chunkserver only needs to send the data to one other chunkserver, which reduces the total network load. The data is stored in each chunkserver's internal memory, not written to the chunk on disk yet.
3. **Write Request:**<br>The client sends a write request to the **primary**. The request includes the data's location in each chunkserver's memory and the offset within the chunk where the data should be written.
4. **Write Operation:**<br>The primary assigns a sequence number to the operation and writes the data to its own replica of the chunk at the specified offset. It then sends the write command (including the sequence number and offset) to all secondary replicas.
5. **Secondary Replicas Write:**<br>Each secondary replica applies the write operation at the specified offset in the same order as defined by the primary's sequence number.
6. **Acknowledgment and Verification:**<br>After the write operation, each secondary replica replies to the primary. Once the primary has received responses from all the secondary replicas, it replies to the client. If the client does not receive a successful reply (due to a timeout or error), it retries the operation.
7. **Finalizing the Write:**<br>Only after the write operation is successful and acknowledged by all replicas, the data is actually considered written to the file. Until this point, the data that was pushed to the chunkservers' memory is considered temporary and not part of the chunk.

{{< paperfig src="/Sources/the-google-file-system/flow.png" alt="Description of image" width="60%" figNum="2" paperTitle="The Google File System" year="2003" paperLink="https://research.google/pubs/pub51/" >}}

## Consistency

### Lease

**A lease is a time-limited contract granted by the master to one of the replicas (the primary) for a chunk. The lease lasts for a specific period, during which the primary replica has the authority to manage updates (writes or appends) to that chunk.**

Here are the main purposes of having leases in GFS:

1. **Ensuring Consistency:**<br>The primary replica determines the order of updates to its chunk. By granting a lease to a primary, GFS ensures that there is exactly one authority responsible for ordering updates, which avoids conflicts and ensures consistency across all replicas.

2. **Reducing Master Load:**<br>Leases reduce the load on the master because once a lease is granted, the master doesn't need to mediate every single update to the chunk. Clients interact directly with the primary replica for writes or appends during the lease period.

3. **Handling Failures:**<br>If a primary replica becomes unavailable (due to a server crash, for example), the master can grant a new lease to one of the other replicas, making it the new primary. This allows GFS to recover quickly from failures.

4. **Improving Performance:**<br>The use of leases allows the primary to cache the chunk's mutation order locally, which can improve performance by reducing the need for synchronization between servers.

### Versioning

**Each chunk is assigned a version number, and this is incremented whenever a chunk is mutated. If a chunkserver has been disconnected and missed an update, its chunk's version number will be out of date. The master server will not include out-of-date replicas in responses to client requests.**

By smart updating the version number, the GFS can achieve weak consistency.

1. **Master's Version Update:**<br>When a mutation operation is *proposed* (e.g., a client wants to append data to a chunk), the master increments the version number of that chunk in its metadata (memory). The updated version number is then sent to the primary replica along with the lease for the mutation.
2. **Primary Replica's Version Update:**<br>The primary replica, upon receiving the lease and the updated version number from the master, applies the mutation and updates its own version number for that chunk.
3. **Secondary Replicas' Version Update:**<br>The primary replica forwards the mutation order to the secondary replicas. They apply the mutation in the same order and update their local version numbers for that chunk to match the primary's.
4. **Master Metadata Commit:**<br>After the primary replica reports back to the master that the mutation has been successfully applied across all replicas, the master commits the updated version number to its operation log. This log is stored on the master's local disk and replicated on remote machines for reliability.
5. **Master and Chunkserver Synchronization:**<br>The master periodically communicates with each chunkserver in HeartBeat messages to ensure they have the same version numbers for their chunks. If a chunkserver has been disconnected and missed an update, its chunk's version number will be out of date. The master will detect this during the next HeartBeat message exchange and will not include the out-of-date replica in responses to client requests.
6. **Garbage Collection:**<br>Stale replicas with outdated version numbers are not immediately deleted. Instead, they are left for a lazy garbage collection process, which periodically reclaims the space.


### Failure Recovering

When a chunkserver fails and then recovers, it doesn't need to wait for a garbage collection cycle to reconnect to the cluster. As soon as it's back online, **it re-establishes a connection with the master by sending a Heartbeat message.** This message includes the state of all chunks that it has, including their version numbers. The master will then use this information to update its records and to coordinate the recovery process.

**if the master identifies any chunks that are under-replicated due to the chunkserver failure, it triggers re-replication to bring the replication level back to the desired threshold.**

### Garbage Collection

In the Google File System (GFS), garbage collection is a mechanism that is used to clean up and reclaim space from unused or unnecessary data. Here's a high-level overview of how garbage collection works in GFS.

1. **Deferred Deletion:**<br>When a file is deleted, the master does not immediately remove the file metadata. Instead, it renames the file to a hidden name within a special directory. This operation is atomic and requires minimal immediate consistency checking.
2. **Master Garbage Collection:**<br>The master periodically scans its entire namespace as part of the garbage collection process. During this scan, it removes the metadata for hidden files that were deleted more than a certain amount of time ago (the default is three days).
3. **Chunkserver Garbage Collection:**<br>At the same time, the master sends a list of all valid chunks (i.e., chunks that are still part of active files) to each chunkserver. The chunkservers compare this list with their local list of chunks. Any chunk not on the master's list is considered to be stale and is deleted to reclaim space.
4. **Reclamation of Failed Chunks:**<br>If a chunkserver fails during a mutation operation, the master marks the affected chunks as failed. The master will not use these chunks to satisfy read requests but will keep them around for garbage collection.

**Re-replication:** If the deletion of stale or failed chunks causes the replication factor for a chunk to fall below the specified threshold, the master will instruct the chunkservers to create additional replicas to maintain the desired level of redundancy.

Garbage collection in GFS is designed to be "lazy" in that it postpones the work of deletion until the master's regular scanning period. This design reduces the load on the master and simplifies the deletion process by reducing the need for immediate, distributed, consistent deletion across all replicas.


**In the Google File System (GFS), garbage collection serves as a kind of "diagnostic scan" and cleanup process that helps maintain the health and efficiency of the system periodically.**

* The master server scans its entire **namespace**, identifying files that have been deleted but whose **metadata** still remains. These files, which have been renamed and moved to a hidden directory, are fully removed after a certain time period.
* The master **communicates** with the chunkservers, sending each a list of valid chunks. The chunkservers compare this list with their local chunk lists, and any chunks not on the master's list are considered stale and can be deleted.
* **Failed/deleted chunks are handled**, either through deletion or re-replication, depending on their status and the health of the overall system. If a chunkserver fails during a mutation operation, for instance, the master marks the affected chunks as failed. The master doesn't use these chunks for read requests, but keeps them for possible re-replication or deletion during garbage collection.
* Re-replication of under-replicated chunks is initiated by the master to maintain the desired level of redundancy.
