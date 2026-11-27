# RightyO capture-to-dispatch swimlanes

A Mac can show **Listening** before haild has a working recognizer. A child can emit a final transcript before it decides whether to send a request. An acknowledgement can play before the target accepts input. Follow the first diagram down to the last boundary with evidence, then use the branch diagrams to find what can happen next. [HS #1483][hs1483]

[Named request](#1-a-named-request-on-a-public-mac-stream) · [Unnamed statement](#2-an-unnamed-owner-statement) · [Privacy switch](#3-entering-and-leaving-privacy) · [Stale holder](#4-why-privacy-can-come-back-after-off) · [Meeting](#5-an-explicit-meeting-or-an-inferred-second-speaker) · [ASR loss](#6-asr-timing-retry-and-missing-words) · [Child failure](#7-child-startup-failure-reload-and-retry) · [Reply and echo](#8-acknowledgement-reply-playback-and-echo)

**How to read the map.** The eight columns in the sequence are responsibilities. RightyO coordinates ASR and identity. For a public turn, the child can send bounded text and context over HTTPS to a configured hosted provider for a recipient and attention label. A transient provider failure can yield an unavailable decision for that turn. Given a decision, the child applies its own name, mode and follow-up gates. Privacy spans the child and haild. The reply lane includes host delivery and Station playback. See `providers.py:725`, `providers.py:773`, `prototype.py:1891`, `tool_events.py:3559`.

Follow the arrows within each flowchart lane. In §7 the retry arrows link individual Mac and haild steps, so those lanes run left to right. Labels between lanes name the data or control exchanged. A conditional arrow applies only to the event it names. A node marked “(other outcomes: see source / inferred)” sends the reader to the cited implementation where a single diagram cannot distinguish the remaining paths. A **K** number marks a known failure. An **S** number marks a suspected failure point whose link to an incident is **(inferred)**. A repeated number denotes the same point throughout.

**Revisions.** The diagrams trace merged main at [Hailing Station `c36e1497`][hs-main] and [RightyO `f134780`][ry-main]. Thresholds are source defaults unless an issue gives a value for a particular incident. Device observations come from the linked reports. The [RightyO issue record][ry340-status] identifies #343–#349 as pre-existing privacy and authority bugs. Their individual reports describe synthetic cases and ask for confirmation on main. The #350 exit has a confirmed synthetic replay on the pinned main (§3).

**Source key.** Swift citations refer to Hailing Station. Python citations are under `src/rightyo/`. The [audio decision map at `c36e1497`][decision-map] covers Mac capture (**M**), haild (**H**), RightyO (**R**), multi-device state (**D**), iOS capture and recovery (**I**), and playback (**P**). Steps outside its coverage cite source directly. Child protocol events travel on stdout. Child diagnostic reasons travel on stderr, which haild ordinarily drains and counts. Device events require diagnostics. A missing host log line alone cannot locate a lost turn. See `RightyoChildSupport.swift:128`, `RightyoChildProcess.swift:64`, `DeviceDiagnostics.swift:501`.

## 1. A named request on a public Mac stream

Read downwards. This example uses the enrolled owner's opening address and the already selected target. The target adapter can return a reply later. The child loads the configuration at spawn. On an already-open stream, start at the next PCM chunk. The sequence assumes successful startup and follows an ordinary public final. Sections 3–7 cover mode changes, missing finals and startup failures.

```mermaid
sequenceDiagram
    participant M as Mac capture
    participant H as haild
    participant C as RightyO child
    participant A as ASR
    participant I as identity + attention
    participant P as privacy
    participant D as dispatch
    participant R as reply
    M->>M: Permission, default input, plain engine and tap
    Note over M,H: K01 Listening can coexist with zero children
    M->>H: First mono PCM chunk, new stream, sequence zero
    H->>H: Admit format, owner, target, binding and rate
    H->>P: Resolve this connection and other privacy holders
    P-->>H: Public start
    H->>C: Spawn listen in stdin mode with config and fresh session
    par Child startup
        C-->>H: session.started advertises features
    and Public audio
        H->>C: Write admitted PCM to bounded stdin
    end
    Note over M,C: S01 capture loss / S02 transport or admission loss
    C->>A: Frame PCM, track diarization, close speech window
    A->>I: Decoded units with timing, speaker coverage and turn boundaries
    I->>C: Public final, role and acceptance-time mode evidence
    C->>C: Queue public transcript
    alt activation=disabled
        C-->>H: transcript
        H->>P: Check live final for an owner privacy command
        Note over C: Continue listening without queueing the turn<br/>No attention or request
    else Hosted decisions enabled
        par Stdout drain and host handling
            C-->>H: transcript
            H->>P: Check live final for an owner privacy command
            P-->>H: Ordinary speech
        and Decision processing
            C->>C: Attempt to enqueue turn for decision
            Note over C,I: For a retained turn, the hosted call can return a decision
            I->>I: Apply name, mode and follow-up rules
        end
        alt Child publishes an attended request
            C-->>H: attention with request ID, then request in stdout order
            Note over H,C: Allow system, or unknown with follow_up=true<br/>Every follow-up requires advertised conversation mode
            alt Recipient or follow-up fails admission
                Note over H: other_human and known_speaker always fail the recipient check
                H->>H: Reject attention with input invalidEvent and end run before reading request
            else Recipient and follow-up checks pass
                H->>H: Validate attention and request, check provenance, withdrawal, ID claim and echo
                alt Ordinary unrouted request reaches the adapter attempt
                    H->>P: Check current hold
                    H->>D: Resolve target and binding, check prompt size
                    D->>R: For this unrouted request, show heard and schedule eligible ack
                    D->>D: Attempt adapter handoff under current policy
                    opt Reply ownership committed and target sends a reply
                        D-->>R: Offer correlated reply to originating peer
                        R-->>M: Playback feeds the mic guard in §8
                    end
                else S03 No adapter attempt
                    Note over H,D: (other outcomes: see source / inferred)
                end
            end
        else Child publishes no request for this turn, including formation failure S17
            Note over C,I: (other outcomes: see source / inferred)
        end
    end
```

The stdout loop emits queued events in order. The hosted call can start before haild reads the transcript, but the transcript reaches haild before its attention and request, if emitted. Override or dismissal records can intervene. A turn already evicted from transcript memory is skipped at decision time. On the tool path, a full decision queue or exhausted provider request budget ends the attention session with an error. See `prototype.py:1129`, `prototype.py:1138`, `prototype.py:1871`, `prototype.py:2365`, `tool_events.py:3809`, `tool.py:431`.

| Point | What crosses the boundary and what can fail | Decision map and source |
|---|---|---|
| **K01 · Listening with no listener** | The app tracks local capture/intent. haild's `ambient_started` marks a registered run. Child `session.started`, a public final, a `request` and a completed adapter handoff are successive, independently observable events. The epic reports an on indicator with zero live children during a restart loop. See §7. [HS #1483][hs1483] | H09, H17, R20 · `StationCard.swift:304`, `ListeningPrivacyRailState.swift:123`, `WebSocketListener.swift:1807`, `RightyoAmbientPipeline.swift:315`, `HostSession+Routing.swift:325` |
| **S01 · No usable capture** | Startup needs a current binding, an active scene, mic permission and a running tap on the default input. A route read can reuse cached input. A stall can restart the engine or end capture. Conversion produces 16 kHz signed PCM16 mono in 100 ms chunks. Backlog drops old source buffers before sequencing or old encoded chunks afterwards. An apparent missing onset could lie on either side of that distinction. [HS #1440][hs1440], [HS #1483][hs1483] | M02–M03, M08 · `StationPlatform.swift:79`, `MacDefaultAudioSessionBackend.swift:66`, `Capture.swift:238`, `Capture.swift:290`, `AmbientAudioStreamer.swift:75`, `AmbientAudioStreamer.swift:179`, `AmbientAudioStreamer.swift:418` |
| **S02 · Lost before ASR** | A valid fresh start may take over a stream. An automatic resume yields to another active peer. A stale selection or invalid start/sequence can refuse input. A new stream without byte credit is refused. An active stream can drop over-rate chunks silently before sustained excess ends it. Main remembers the last 64 takeovers and, by default, 4,096 ended IDs. After eviction the corresponding moved or ended-ID check no longer recognizes the old stream. All other admission checks still apply. Ingress, reload and stdin queues can drop audio under pressure. Public forward gaps get bounded silence fill (up to 3 s against elapsed time). It preserves some timing but cannot recover the words. [HS #1483][hs1483] | D07, H11, H16 · `HostSession+Routing.swift:96`, `AmbientAudioGate.swift:132`, `AmbientAudioGate.swift:254`, `AmbientAudioGate.swift:291`, `AmbientAudioGate.swift:468`, `WebSocketIngressPump.swift:112`, `RightyoAmbientPipeline.swift:406`, `RightyoStdinWriter.swift:44` |
| Named and addressed | Timestamped units join or split at speaker and loss boundaries. A bound owner's opening configured name can promote an available `uncertain` decision. A direct `attend` to the system also works. Meeting, media, guest-address, dismissal and stop gates can still win. Final attention and request carry the correlation ID. An eligible request engages the speaker after emission. | R07–R13, R15–R20 · `live_audio.py:2413`, `turn_merge.py:391`, `tool_events.py:1581`, `tool_events.py:1742`, `tool_events.py:3577`, `tool_events.py:3945`, `tool_events.py:3970` |
| Host attention admission | On main, the opening-name promotion changes the label to `attend` and preserves the provider's recipient. For an `attention` with `attend` and a request ID, haild requires `recipient_kind=system` or `recipient_kind=unknown` with `follow_up=true`. Any follow-up also requires the session to have advertised conversation mode. Both `other_human` and `known_speaker` fail the recipient check. A promoted `unknown` without the flag also fails. Haild ends the run with `input invalidEvent` on the attention record, before it consumes the request. | H12–H13, R20 · `tool_events.py:3599`, `RightyoInputEvent.swift:319`, `RightyoInputConsumer.swift:938`, `RightyoAmbientPipeline.swift:315` |
| **S17 · Final recognized but request formation fails** | After the child decides to attend, an optional request former can raise or return unusable text. The child ends the session before emitting the request. A final transcript alone cannot distinguish this path from an attention refusal. [HS #1483][hs1483] | R13, R20, H15 · `tool_events.py:4045`, `tool_events.py:4082`, `RightyoInputConsumer.swift:714` |
| **S03 · A request exists but the target gets no input** | haild checks session, sequence, provenance, prior withdrawal and echo, then privacy and local controls. An owner-addressed route needs a resolvable binding. An ambiguous route or pending input can refuse just this request. Confirmation can hold a request for a capable peer or refuse it for Station. A policy/rebind or other terminal failure can end the run. For a routed request the heard notice and ack wait for handoff. The unrouted ack above is asynchronous. [HS #636][hs636], [HS #894][hs894] | H12–H13, H19–H20, R20, P10 · `RightyoInputConsumer.swift:625`, `RightyoInputConsumer.swift:1031`, `RightyoInputConsumer.swift:1079`, `HostSession+Routing.swift:211`, `HostConnection+Protocol.swift:20`, `RightyoAmbientPipeline.swift:45` |

## 2. An unnamed owner statement

The diagram starts after the mode checks, with media off, no explicit or automatic meeting and an available decision on an unnamed public owner turn that nobody else answered. With media on at turn acceptance, the missing name blocks even a direct `attend` to `system`. The child emits `ignore` and no request. Direct classification can run without an open conversation. Follow-up promotion uses **the time speech started**, the engaged speaker and the probability of `attend`. A separate dismissal cooldown compares the provider’s confidence in its chosen label with `cooldown_min_confidence`. An unnamed turn below that floor is withheld. See `tool_events.py:1856`, `tool_events.py:2279`, `tool_events.py:3559`, `tool_events.py:3626`.

```mermaid
flowchart LR
    subgraph child["RightyO child"]
        direction TB
        final["Public, unnamed owner final<br/>Media off, no meeting, mode checks passed"]
        replyCue["Prior engaged speaker,<br/>request and reply cue"]
    end
    subgraph identity["identity + attention"]
        direction TB
        direct{"Effective label and recipient<br/>after mode checks?"}
        eligible{"Same engaged speaker in window<br/>or qualifying spoken-reply cue?"}
        follow{"Uncertain, eligible recipient,<br/>follow-up bar and cues pass?"}
        lapsed["K02 No follow-up promotion"]
        yes{"Stop, dismissal, cooldown,<br/>supersession or withdrawal?"}
        no["Attention without request ID"]
        direct -->|attend to system| yes
        direct -->|uncertain| eligible
        direct -->|ignore or attend to another recipient| no
        eligible -->|yes| follow
        follow -->|yes| yes
        follow -->|no S04| no
        eligible -->|neither| lapsed --> no
        yes -->|veto| no
        yes -->|clear| publish{"Request formed and published?"}
        publish -->|yes| emit["Emit attention with ID, then request"]
        publish -->|no S17| other["(other outcomes: see source / inferred)"]
    end
    subgraph host["haild"]
        direction TB
        recipient{"System, or unknown with follow_up=true?<br/>Any follow-up in advertised conversation mode?"}
        recipient -->|no| invalid["Reject attention: input invalidEvent<br/>End run before reading request"]
        recipient -->|yes| consume{"Matching request passes validation,<br/>claim, withdrawal and echo checks?"}
        consume -->|no| hostOther["(other outcomes: see source / inferred)"]
        consume -->|yes| admitted["Check privacy and local commands"]
    end
    subgraph privacy["privacy"]
        direction TB
        veto{"Ordinary request while private?"}
        veto -->|yes| drop["Consume and drop request"]
        veto -->|no| forward["Apply remaining local controls and routing"]
    end
    subgraph dispatch["dispatch"]
        admit["Resolve binding and<br/>attempt handoff in §1"]
    end
    child -->|turn and context| identity
    identity -->|attention with request ID, then request| host
    host -->|admitted request only| privacy
    privacy -->|eligible public request only| dispatch
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| Inside the window | A request from an eligible stable, non-overlapping speaker opens or extends engagement. The usual time test is `from_ms <= start_ms < until_ms`. Conversation defaults, when enabled, are 20 s and a 0.4 follow-up floor. The setup described in RightyO #342 uses 0.5. A qualifying `uncertain` turn to system/unknown can become `attend` with `follow_up=true`. An enrolled-role floor, an appendix, a pending question or a request-linked spoken reply can change the applicable bar, cue or window. [RightyO #342][ry342] | R17–R18 · `contracts.py:23`, `contracts.py:539`, `tool_events.py:1878`, `tool_events.py:2936`, `tool_events.py:2987`, `tool_events.py:3321` |
| **S04 · Plausible follow-up stays unsent** | An in-window turn can fail on its speaker, recipient, probability, required cue, courtesy/closing, another person's answer, unavailable evidence, or a mode veto. An old engagement cannot grant a guest a follow-up. Inspect `follow_up outcome=refused reason=…` when emitted and `attention` without a request ID. A provider error can independently leave an unavailable decision or end the session. [RightyO #340][ry340], [HS #1483][hs1483] | R13–R19 · `prototype.py:1873`, `tool_events.py:2936`, `tool_events.py:3027`, `tool_events.py:3087`, `tool_events.py:3809` |
| **K02 · Statement after the window lapses** | On main an unnamed owner gets neither the opening-name promotion nor an expired speaker's follow-up. A direct attend-to-system can still send if the mode and remaining attention checks pass. The epic reports missing owner statements after expiry. Voiceprint ownership alone supplies no instruction to send. [HS #1483][hs1483], [RightyO #340][ry340] | R16–R20 · `tool_events.py:1878`, `tool_events.py:2951`, `tool_events.py:3559`, `tool_events.py:3577`, `tool_events.py:3945` |

## 3. Entering and leaving privacy

A tap is a host control. Haild recognizes spoken **entry** on a public child event. The private child recognizes spoken **exit**. Haild withholds private PCM from each child until it proves it can handle it. An answer outstanding on this connection at entry cannot play after Off. See `HostReplyDelivery.swift:1759`.

```mermaid
flowchart LR
    subgraph mac["Mac capture"]
        tap["Tap On or Off<br/>wait for host notice"]
    end
    subgraph host["haild"]
        direction TB
        event{"Eligible public event?"}
        event -->|live non-echo final| voice
        event -->|claimed non-echo request| seen
        seen{"Request for one of the last 32<br/>matched transcript IDs?"}
        seen -->|yes, request still matches a command| held["Hold request without repeating command"]
        seen -->|no, including eviction| voice
        seen -->|yes, no command match on request| normal
        voice{"Match in eligible live final<br/>or request's own heard words?"}
        voice -->|verified enrolled owner entry| enter["Request On"]
        voice -->|owner entry without voiceprint| unverified["S06 Hold and select refusal clip"]
        voice -->|non-owner entry or negation| deny["S06 Hold silently"]
        voice -->|owner negation| still["Hold and acknowledge negation"]
        voice -->|partial in owner request| hint["Hold and give privacy hint"]
        voice -->|no match or other partial| normal["No voice command<br/>Continue normal handling"]
        device{"Device switch passed to router:<br/>requested state versus current arming?"}
        device -->|change to On| enter
        device -->|change to Off| off["Report Off to this connection's pipelines"]
        device -->|same state or intervening arming change| same["No change"]
        exit{"Child privacy.exit while host armed?"}
        exit -->|yes| off
        exit -->|no| stale["Ignore stale exit"]
        off --> clear["Clear host arming even if no pipeline accepted Off"]
        clear --> release["If still off, release future replies<br/>Then issue device Off notice"]
    end
    subgraph child["RightyO child"]
        direction TB
        local{"Match on turn wholly within<br/>current private period?"}
        local -->|verified name alone| remember["Remember name end for the next turn"]
        local -->|approved named or split exit| leave["Emit privacy.exit<br/>K15 Extra words can still match"]
        local -->|status if no name-only or approved exit took precedence| stat["Emit privacy.status"]
        local -->|otherwise S06| discard["No event, stay private"]
        received{"Valid Off received on stdin?"}
        received -->|plain| applied["Apply Off"]
        received -->|positioned| position{"Target sample processed and<br/>caught up with received PCM?"}
        position -->|yes| applied
        position -->|no| waitOff["Keep Off pending until caught up<br/>A later mode control can supersede it"]
    end
    subgraph priv["privacy"]
        direction TB
        entry{"Result of On request on active stream?"}
        entry -->|already armed on voice entry| recheck["Keep privacy and open another entry for proof"]
        entry -->|off, no pipeline took On| refused["Stay off, select not-sent clip"]
        entry -->|off, at least one pipeline took On| armed["Arm connection, drop outstanding reply records<br/>Gate ordinary requests and replies"]
        recheck --> proof
        armed --> proof{"Child keeps the current On wish?"}
        proof -->|yes| localPCM["Admit private PCM to this child"]
        proof -->|pending| closed["Withhold PCM until proof settles"]
        proof -->|other S05| other["(other outcomes: see source / inferred)"]
    end
    subgraph reply["reply"]
        notice["State notice first,<br/>eligible confirmation clip next"]
    end
    mac <-->|set_privacy / duck_mode| host
    host <-->|delivered duck control / final, proof, exit or status| child
    child <-->|proof or refusal / PCM admission| priv
    host -->|active-stream On request| priv
    priv -->|entry result| reply
    host -->|Off notice, then clip if a pipeline accepted Off| reply
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| Tap and live entry | Station sends `set_privacy` and shows pending until a current `duck_mode` notice or a 10 s UI timeout on the pending switch. The device switch needs no voice check. Off can reach the router after this connection’s stream ends. A same-state switch normally does nothing. On voice entry haild checks a live non-echo final as it consumes the transcript and checks the subsequent request if needed. For an enrolled owner, `voiceprint` or `voiceprint_label` can authorize entry. The consumer remembers the last 32 matching transcript IDs. While the ID is retained, a matching request is held without repeating the command. After eviction the request checks its own words and current owner evidence. It can issue `.enter` again for the same utterance. The synthetic hold-back test observes both commands and zero deliveries. A pre-stream On follows §4. | D01–D02, H14, R22 · `HostConnectionStore.swift:538`, `HostConnectionStore.swift:706`, `AmbientAudioGate.swift:234`, `WebSocketListener+DuckMode.swift:112`, `RightyoInputConsumer.swift:798`, `RightyoInputConsumer.swift:812`, `RightyoInputConsumer.swift:828`, `AmbientPrivacyHoldBackTests.swift:29` |
| **S05 · On accepted but the listener cannot prove privacy** | First distinguish **no child takes On while off** (stay off, refusal notice/clip) from **already armed but proof fails** (stop/refuse the child, keep privacy). For start-private, inspect the `session` event with `phase=started`. Its top-level `duck` object must carry `duck.version >= 3` and the Boolean `duck.private == true`. The default deadline is 10 s. For running children, each written On needs a `privacy.on` acknowledgement, default 5 s. Haild holds output, closes conflicting modes and gates PCM. The entry ledger waits for proof across participating children before queuing the success clip. Recovery can announce success after an unavailable result without a new tap. [HS #735][hs735], [HS #1483][hs1483] | H11, H14, D02, D05 · `tool_events.py:1165`, `RightyoAmbientPipeline.swift:416`, `RightyoAmbientPipeline.swift:524`, `RightyoAmbientPipeline.swift:566`, `RightyoAmbientPipeline.swift:595`, `RightyoAmbientPipeline.swift:1013`, `RightyoAmbientPipeline.swift:1187`, `RightyoAmbientPipeline.swift:1300`, `WebSocketListener.swift:2597`, `WebSocketListener+PrivacyEntry.swift:127`, `WebSocketListener+DuckMode.swift:139` |
| **S06 · Voice control changes nothing** | Haild silently consumes a non-owner’s standalone entry phrase. Owner-role without live voiceprint gets the refusal clip. An owner's negation leaves recording as it was. Only an owner request can trigger the hint for a partial command. While private the child runs the local matcher in memory, suppresses ordinary finals, attention, requests and acks and silences private diarizer input. Status is available to anyone. Exit needs the name and exit phrase entirely within the current privacy period, with binding or isolated owner-voice proof, no inferred attribution or playback conflict. A split exit authenticates **both** turns. The second must start within 4 s of the verified name’s end. Unverified speech leaves privacy on. An intervening turn can interrupt a split exit (§6, S12). [HS #735][hs735], [RightyO #340][ry340] | R22, H14 · `RightyoInputConsumer.swift:841`, `live_audio.py:1919`, `tool_events.py:126`, `tool_events.py:2022`, `tool_events.py:2071`, `tool_events.py:2139` |
| **K15 · Extra words can end Privacy (#350)** | The exit matcher accepts a configured name followed by an exit phrase even when more words follow. A synthetic replay on RightyO main confirmed a content-free `privacy.exit` for a bound owner both in a single turn and after a separate verified name within the split window. The same continuation without either name emitted no exit. Haild acts on the exit event without hearing the private words. [RightyO #350][ry350] | R22 · `tool_events.py:380`, `tool_events.py:391`, `tool_events.py:2068`, `RightyoInputConsumer.swift:856` |
| Pending public decisions at Privacy On | A public turn can still receive its decision after On. #343 tracks a pending meeting request emitted after speaker bindings were forgotten. Haild drops an ordinary request it consumes while private. #344 tracks a public owner cancellation decided after On that leaves an earlier request open. The evidence to distinguish the two is a child `request` versus a `dismiss` identifying the withdrawn request. [RightyO #343][ry343], [RightyO #344][ry344] | R19–R20 · `tool_events.py:1951`, `tool_events.py:2217`, `tool_events.py:3663`, `RightyoInputConsumer.swift:648`, `RightyoInputConsumer.swift:798` |
| Discarded text and mixed speakers | When a decode crosses a privacy boundary, the child can discard it. #345 tracks discarded private text reaching a callback. #346 tracks a guest's privacy phrase being credited to an owner's quoted words in the same window. A private exit reports only the action to haild, so the host event cannot identify the words or speaker behind it. [RightyO #345][ry345], [RightyO #346][ry346] | `live_audio.py:1735`, `live_audio.py:2548`, `tool_events.py:391`, `tool_events.py:2022` |
| Host Off and clips | When a private turn yields a protocol event, the child emits a content-free `privacy.exit` or `privacy.status`. Haild ignores a stale exit while already off. On a current voice exit or device switch to Off, haild reports Off to the connection's pipelines, clears its arming even if none accepts, and withdraws open privacy entries. On the serial notice queue, reply-hold release comes **before** the device's `duck_mode` notice. The release checks that privacy is still off when it runs. The `confirm-privacy-off` clip is eligible after the notice when at least one pipeline reports acceptance. Before `session.started`, recording the Off wish returns true, so the clip can precede the child write. Entry, status and refusal use separate clips. These controls never dispatch to the target. | D04–D05, H14, R22 · `RightyoInputConsumer.swift:856`, `WebSocketListener+DuckMode.swift:56`, `WebSocketListener+DuckMode.swift:93`, `WebSocketListener+DuckMode.swift:153`, `WebSocketListener.swift:2610`, `WebSocketListener.swift:2629`, `WebSocketListener.swift:2784`, `WebSocketListener.swift:2802`, `RightyoAmbientPipeline.swift:1163` |
| Child Off boundary | If a child launched private and Off is still wanted when it proves its private start, haild then attempts the deferred Off write. For stdin with `duck_after_sample` support, haild attempts `duck=false` with `after_sample`. A retryable write can be retried for up to 500 ms. A failed or expired write can leave the child private after host Off. It applies Off when it has processed the specified sample and caught up with received PCM. Until then the child keeps the Off pending and stays private. A delivered plain Off applies on receipt. At the child boundary a clean diarizer audit can preserve bindings and conversation. An uncertain audit with input can force renewal. | H11, H14 · `RightyoAmbientPipeline.swift:1197`, `RightyoAmbientPipeline.swift:1201`, `RightyoAmbientPipeline.swift:1221`, `RightyoChildControl.swift:87`, `prototype.py:1795`, `prototype.py:2157`, `prototype.py:2203`, `prototype.py:2251`, `tool_events.py:2195` |

## 4. Why privacy can come back after Off

Connection B attempts to open a new stream. The reconnect edges start after Station reauthorizes the same selection on a new connection generation, with no pending local privacy request. They assume capture remains available to resume. A is an older socket that held privacy. One physical device can account for both. Inheritance is decided **before** child creation on a fresh or resume start.

```mermaid
flowchart LR
    subgraph mac["Mac capture"]
        direction TB
        resume{"How does B open the stream?"}
        resume -->|automatic reconnect, previously private| reassert{"Reassert On before PCM:<br/>send succeeds and current On arrives in time?"}
        reassert -->|yes, restore still current| autoStart["Start with resume flag"]
        reassert -->|confirmation fails| veto["S08 End this restore before PCM"]
        reassert -->|attempt superseded| obsolete["Ignore obsolete completion"]
        resume -->|automatic reconnect, previously public| autoStart
        resume -->|fresh owner start| fresh["Start without resume flag"]
        off["Owner turns B off"]
    end
    subgraph host["haild"]
        direction TB
        admission{"Otherwise valid start while<br/>another connection is active?"}
        admission -->|resume, other active| moved["Refuse as moved, leave peer listening"]
        admission -->|fresh, other active| take["Take over after admission"] --> source
        admission -->|no other active connection| source
        source{"Privacy source at child creation?"}
        source -->|none| clean["Public start"]
        source -->|B already armed| guarded["Start B private"]
        source -->|B unarmed, source elsewhere| inherit["Arm B and queue restore notice"]
        inherit --> guarded
        inherit --> notice{"Asynchronous notice result?"}
        notice -->|sent| shown["Host sent the notice"]
        notice -->|failed or unsupported| still["S07 Leave arming in place"]
        notice -->|no connection or nil| tokenB{"Same restore token on B?"}
        tokenB -->|yes| undo["Undo this restore"]
        tokenB -->|no| unchanged["Leave current state alone"]
        offB["Owner Off clears B, all parks and overflow"]
        offB --> scoped{"Did B inherit from a recorded live source A?"}
        scoped -->|no| others["Other live holders keep counting"]
        scoped -->|yes| claims{"Listener available and claims match<br/>using live or matching parked claims?"}
        claims -->|no| keep["K03 Leave source contribution unchanged"]
        claims -->|yes| ping{"Probe A"}
        ping -->|pong| keep
        ping -->|stale| active{"A has an unretired run?"}
        active -->|yes| keep
        active -->|no| token{"Where is the recorded arming now?"}
        token -->|live on A| retire["Exclude this token as a source<br/>Later life can restore it"]
        token -->|in A's park| forget["Drop only A's matching park"]
        token -->|neither| keep
    end
    subgraph child["RightyO child"]
        direction TB
        ordinary["Public start"]
        pre["--start-private: withhold PCM"] --> proved{"Start-private proof?"}
        proved -->|pending| waitProof["Keep withholding PCM"]
        proved -->|confirmed| listen["Keep private, or attempt deferred Off in §3"]
        proved -->|missing at deadline or invalid at started| refuse["Refuse child"]
    end
    mac <-->|start, reassert or Off / notice| host
    host <-->|chosen start mode / child proof| child
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| Restore and park | A counting holder's disconnect parks its arming in RAM. Haild keeps up to 16 parks, one per connection, without age expiry. Adding a seventeenth distinct park evicts the oldest and latches overflow. Overflow alone keeps a new stream private even after individual parks are gone. An unarmed B prefers a counting live holder, then the latest park, then overflow alone. Any of them arms B irrespective of device match. Restore ends conflicting mode state, holds replies and sends `duck_mode` with `reason=device`. It leaves the source in place. A hello snapshot is read-only and requires `mode_snapshot`, which this Station hello omits. | D02–D03, D08, H09 · `WebSocketListener+PrivacyPark.swift:45`, `WebSocketListener+PrivacyPark.swift:70`, `WebSocketListener+PrivacyPark.swift:106`, `WebSocketListener.swift:959`, `WebSocketListener.swift:1643`, `WebSocketListener.swift:1707`, `HostConnection+Protocol.swift:20` |
| **K03 · Stale holder re-arms listening after Off** | In #1456 the iPhone restarted Ambient after the #1455 route stop. Haild restored Privacy from an older connection of the same phone and launched the child private. Off cleared B, but A kept its hold and the next start on B inherited Privacy again. Force-quitting the app left a half-open host socket. Compare `ambient_privacy_restored source=live device_match=false` with `ambient_privacy_off_scoped`. Off clears parks and overflow. Only B's recorded live source is judged. Haild can use A's matching parked claims if A disconnected during scoping. Matching claims permit the ping. A pong yields `live` even if A has rearmed. Only after a stale probe does haild check for an active child (also `live`), then compare the current arming with the one B inherited. If neither the live arming nor a park matches the recorded token, haild leaves the current state alone. A matching park is removed. A matching live arming is provisionally excluded from future restores while A itself stays private. A late pong can reinstate it. Hello claims cannot establish a durable physical-device identity. [HS #1456][hs1456], [HS #1439][hs1439], [HS #941][hs941] | D03–D04 · `WebSocketListener.swift:396`, `WebSocketListener.swift:3271`, `WebSocketListener+PrivacyPark.swift:151`, `WebSocketListener+PrivacyPark.swift:177`, `WebSocketListener+PrivacyPark.swift:203`, `WebSocketListener+PrivacyPark.swift:230` |
| **S07 · Arming survives a failed notice** | For a pre-arm/restore, only nil or `no_connection` rolls back a still-matching token. A fresh pre-arm can park first. `failed` and `unsupported` leave the arming. That could supply a later live holder even when the device never saw On. Its contribution to the #1456 incident is (inferred). Separately, the Mac On investigated in #1483 was confirmed as an owner tap. The `device` reason by itself cannot distinguish a tap from reconnect or restore. [HS #1456][hs1456], [HS #1483][hs1483] | D01–D03 · `WebSocketListener+PrivacyPreArm.swift:24`, `WebSocketListener+PrivacyPreArm.swift:57`, `WebSocketListener+DuckMode.swift:180`, `WebSocketListener+PrivacyPark.swift:92` |
| **S08 · Private reconnect stops before PCM** | A previously public Station resumes directly. A previously private Station reasserts On before restarting audio. Both automatic starts carry the resume flag and yield to another active peer. A valid fresh start can take over. On any admitted start, B can still inherit host-side privacy. A new socket can pre-arm with no stream. Reconnect needs a successful send and a current-generation On within 5 s. Old-generation notices cannot satisfy it. Send failure, matching Off or deadline ends the attempt. A snapshot-capable authorized peer can clear parks/overflow by Off even while unarmed. [HS #904][hs904] | D02, D04, D08, D12 · `AmbientListeningReconnect.swift:76`, `AmbientListeningReconnect.swift:414`, `AmbientListeningReconnect.swift:427`, `AmbientListeningReconnect.swift:581`, `AmbientAudioGate.swift:474`, `WebSocketListener+PrivacyPreArm.swift:24`, `WebSocketListener.swift:986` |

## 5. An explicit meeting or an inferred second speaker

Haild attempts `meeting=true` before writing the `media=true` gate. It can report an active meeting when only the media write succeeded. A capable child still awaiting `started` can receive the deferred meeting line after startup. RightyO snapshots the two flags and presence when it accepts each turn. The diagram follows a direct `attend` to `system` through the mode checks. A pass leaves the later attention checks in force. See `RightyoAmbientPipeline.swift:446`, `RightyoAmbientPipeline.swift:455`, `AmbientMeetingControlPathTests.swift:130`, `tool_events.py:2279`, `tool_events.py:3157`, `tool_events.py:3560`.

```mermaid
flowchart LR
    subgraph host["haild"]
        explicit["Explicit meeting control<br/>or S09 restored meeting"]
    end
    subgraph child["RightyO child"]
        accepted["Snapshot meeting, media and presence<br/>when accepting the turn"]
    end
    subgraph asr["ASR"]
        direction TB
        noise["K04 Filler on near-silence"]
        split["K05 Owner split across labels<br/>or missing attribution"]
    end
    subgraph identity["identity + attention"]
        direction TB
        mode{"Child flags at turn acceptance?"}
        mode -->|meeting on, either media value| owner{"Configured name, speaker label<br/>and owner authority?"}
        owner -->|yes| allow["Pass mode checks"]
        owner -->|no| block["K06 Relabel direct attend as ignore"]
        mode -->|meeting off, media only| media{"Configured name and either no<br/>speaker priority or owner authority?"}
        media -->|no| block
        media -->|yes| present
        mode -->|both off| guest{"Ambient guest-address policy active?"}
        guest -->|yes| standing{"Strict owner or guest?"}
        standing -->|strict owner| usual["Continue attention and eligible follow-up checks"]
        standing -->|guest| addressed{"Qualifying opening address?"}
        addressed -->|no| ignore["guest_unaddressed: ignore direct attend"]
        addressed -->|yes| direct["Direct attend can proceed<br/>Guest cannot use owner's follow-up"]
        guest -->|no| present{"Other speaker present in snapshot?"}
        present -->|no| allow
        present -->|yes| auto{"Meeting owner check or verified<br/>opening name in diarized head?"}
        auto -->|yes| allow
        auto -->|no| block
    end
    subgraph dispatch["dispatch"]
        send["Eligible public request<br/>to host admission"]
    end
    host -->|meeting control when supported, plus media gate| child
    child <-->|audio for decode / labelled units for snapshot| asr
    asr -->|speech, timing and label evidence| identity
    child -->|accepted mode| identity
    identity -->|attention and request when eligible| dispatch
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| **S09 · A retained meeting gate** | Explicit meeting, rubber-duck and media controls have host arming and expiry. Privacy takes precedence. A subsequent nonprivate stream can restore a live/parked mode until its original expiry. Meeting can resume **without recording**. Compare `ambient_meeting` / `meeting_restored` with the child's `meeting` / `others_present` flags. No host meeting transition is required for inferred presence. [RightyO #340][ry340] | D09–D10, R14–R15 · `WebSocketListener+MeetingMode.swift:95`, `WebSocketListener+ModeRestore.swift:91`, `WebSocketListener+ModeRestore.swift:161`, `tool_events.py:1534`, `tool_events.py:3295` |
| **K04 · Filler on silence creates presence** | RightyO #340 records a near-silence decode assigned a second label and a **120 s** lockout. On main, `cue_when_others_ms=0` disables this history by default. When enabled, the presence history retains at most 1,000 candidates, evicting the oldest on overflow. A labelled turn meeting duration/word minima (defaults 1,000 ms / 3 words) can enter it. Playback overlap and per-turn owner/trusted roles are excluded. Compare a candidate's end with the new turn's start and engaged/current speaker label. Same-identity evidence can cancel split labels. [RightyO #340][ry340] | R03, R07, R12, R14 · `contracts.py:545`, `tool_events.py:741`, `tool_events.py:3102`, `tool_events.py:3110`, `tool_events.py:3128`, `tool_events.py:3153` |
| **K05 · Owner split or shown as unknown** | Diarization assigns spans. The voiceprint worker scores eligible non-overlapping labelled speech, then binds or stays tentative/unknown. Unlabelled speech, missing enrollment or insufficient strict coverage can leave an actual owner unverified. A split label can count toward presence on main without a positively different voiceprint. The unlabelled-owner score at this pin is diagnostic only. [RightyO #332][ry332], [RightyO #334][ry334], [RightyO #340][ry340] | R07, R09–R11, R14, R23 · `live_audio.py:738`, `live_speaker_id.py:734`, `live_speaker_id.py:845`, `live_speaker_id.py:1131`, `tool_events.py:1575`, `tool_events.py:3110`, `TranscriptTurn.swift:34` |
| **K06 · Named turns ignored in meeting** | On main, explicit meeting needs configured name, label and owner authority. On a media-only snapshot, a named direct attend can pass without speaker roles. With speaker priority configured it also needs owner authority. The automatic meeting check still applies if others are present and the ambient guest-address policy is inactive. Media and explicit meeting both refuse follow-up promotion. Its owner-vocative fallback needs a current voiceprint and an opening name within the diarized head for the same turn end. #340 records positive model attends blocked with `others_present`, `not_owner` or `head_unknown`. A mismatch between the recorded head end and the merged turn end is one possible cause of the reported `head_unknown` (inferred). The optional ask-anywhere setting can promote an eligible owner’s named uncertain turn to `attend` with recipient `system` if the mode bar passes. Automatic meeting refuses ordinary follow-ups. Under the guest-address policy, only a strict owner reaches the follow-up cue check for a possible aside. [RightyO #340][ry340] | R14–R18 · `tool_events.py:2292`, `tool_events.py:2307`, `tool_events.py:2323`, `tool_events.py:2330`, `tool_events.py:2943`, `tool_events.py:2953`, `tool_events.py:2987`, `tool_events.py:3295` |
| Owner authority on a merged turn | #347 tracks a meeting request overriding another speaker's open work when only the opening name has strict owner coverage. #348 tracks a stop or privacy command forwarded on the strength of a verified name even though its control words have inferred attribution. On main, attention and authority are checked separately. Inspect which words supplied the label and whether the merged turn was marked inferred before attributing an override or control to the owner. [RightyO #347][ry347], [RightyO #348][ry348] | R07, R15, R19, R22 · `live_audio.py:2437`, `live_audio.py:2490`, `tool_events.py:1726`, `tool_events.py:3474`, `tool_events.py:3661` |
| Owner stop lost | At the initial binding epoch a configured speaker label takes precedence in the role lookup. It can return an owner role without consulting the speaker's genuine binding to the enrolled owner. #349 tracks the resulting loss of a verified stop for outstanding work. [RightyO #349][ry349] | R10, R19 · `live_speaker_id.py:1712`, `live_speaker_id.py:1744`, `tool_events.py:1590` |

## 6. ASR timing, retry and missing words

The energy gate decides whether there is a window to decode. RightyO validates Whisper timing before handing usable units to the speaker and turn merger. The timing branches describe the local Whisper decoder. The recovery records assume a public window with child reporting enabled.

**S11 · Filler survives timing checks (inferred).** A nonempty decode with valid segment timing can reach attribution. The timing check alone cannot establish whether anyone spoke. See K04 for the reported second-speaker effect. [RightyO #340][ry340]

```mermaid
flowchart LR
    subgraph child["RightyO child"]
        direction TB
        pcm["20 ms PCM after capture S01"] --> active{"Window already open?"}
        active -->|no| onset{"Frame RMS at or above onset threshold?"}
        onset -->|no| pre["Keep frame in bounded pre-roll"]
        onset -->|yes| start["Open with pre-roll"] --> append
        active -->|yes| append["Append frame, including quiet frames"]
        append --> closeNow{"Hangover or duration limit reached, or<br/>end-of-turn complete with attribution ready?"}
        closeNow -->|yes| closeWindow["Finalize window"]
        closeNow -->|no| more["Keep window open for next frame"]
        eof["Clean end of input with open window"] --> closeWindow
    end
    subgraph asr["ASR"]
        direction TB
        raw["Decode and validate local recognizer result<br/>K04 Near-silence filler / S11"]
        raw -->|window returned| capacity{"Admitted within ordered recovery backlog?"}
        raw -->|decoder or document error| failed["Processor failure, see §7"]
        capacity -->|no, overflow| lost["S10 Lost window"]
        capacity -->|yes| timing{"Units after timing checks?"}
        timing -->|none, no rejects| empty["Valid empty decode<br/>No final, retry or recovery record for this window"]
        timing -->|usable, with or without repairs or rejects| ready["Keep usable units in order<br/>Preserve loss boundaries"]
        timing -->|none, with rejects| budget{"Retry slot available?"}
        budget -->|no| lost
        budget -->|yes| retry{"Local retry yields usable units?"}
        retry -->|yes, including partial recovery| ready
        retry -->|no| lost
        boundary["Stop or privacy boundary during processing"] --> boundaryOther["(other outcomes: see source / inferred)"]
    end
    subgraph identity["identity + attention"]
        direction TB
        attr["Attribute, hold or merge<br/>K07 First word split"]
        attr -->|eligible public final| att["Attention in §2 / §5"]
    end
    subgraph priv["privacy"]
        direction TB
        owner["Private matcher and owner check in §3"]
        owner --> next{"Next turn reaching the private matcher?"}
        next -->|timely verified exit continuation| leave["Emit privacy.exit"]
        next -->|ordinary intervening turn| held["S12 Consume pending name, stay private"]
        next -->|otherwise| other["Apply name, exit and status rules in §3"]
    end
    child -->|finalized PCM window and diarizer timeline| asr
    asr -->|timed units and gaps| identity
    identity -->|private turns in order| priv
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| **K04 · Filler** and **K07 · First word split** | Before onset, frames below the default RMS threshold (0.008) fill up to 240 ms of pre-roll. Room noise can open a window and yield filler (§5). An open window keeps quiet frames through hangover (1,440 ms since the last voiced frame). The 12 s cap or clean end of input can close it sooner. A complete end-of-turn verdict waits for timeline coverage of the last voiced audio when using streaming diarization. A failing end-of-turn model falls back to the silence rules. The merger may hold a wake fragment for continuation or release separate turns. A first word in a separate turn was observed. Loss of a first phoneme at capture or onset is a separate possibility (inferred). See S01 and S10. [HS #1440][hs1440], [RightyO #107][ry107], [RightyO #340][ry340] | M08, R03, R05–R08 · `live_audio.py:136`, `live_audio.py:1963`, `live_audio.py:1972`, `live_audio.py:2035`, `live_audio.py:2642`, `turn_merge.py:391`, `turn_merge.py:498` |
| **S10 · Unusable or absent public window** | Quiet speech may never open the gate. Even after onset, a valid empty decode (for example, an empty `transcription` list) can contribute no final, trigger no retry and emit no `asr_window` record. Main clamps small timing faults. Unusable word timing falls back to segment timing. Word timing that backtracks across segments can make the whole window use segment units. Rejected segments leave loss boundaries between usable neighbours. Timing rejections that leave no usable units can trigger a bounded local re-decode. Completed windows publish in order. Deadline, backlog, privacy boundary or stop can cancel or discard work. Public recovery records use `asr_window outcome=salvaged/redecoded/lost`. In the absence of backlog loss or a racing stop/privacy boundary, both a missed onset and a valid empty decode can leave no final or recovery log. [HS #1440][hs1440], [HS #1483][hs1483] | R03, R05–R08 · `live_audio.py:1092`, `live_audio.py:1187`, `live_audio.py:2167`, `live_audio.py:2201`, `live_audio.py:2346`, `live_audio.py:2385` |
| **S12 · Split owner exit interrupted** | The private matcher remembers the end of a verified name-only turn. It consumes that pending name on the next private turn it matches. An intervening ordinary turn clears the name, so a later exit phrase alone cannot complete the split exit. A fresh named exit still gets its own check (§3). | R22 · `tool_events.py:2038`, `tool_events.py:2058`, `tool_events.py:2068` |

## 7. Child startup, failure, reload and retry

The OS exit status and the stdout protocol answer different questions. The order of `started`, terminal event and EOF determines what haild can report. The notice text shown assumes the target session is unchanged. A session change yields `ambient stopped: target session changed`. The retry path follows an active capture receiving an ambient refusal. A successful reload response records installation of the replacement. Its first valid `session.started` is separate evidence of child startup.

```mermaid
flowchart LR
    subgraph mac["Mac capture"]
        direction TB
        start["Send sequence zero<br/>K01 local Listening only"]
        received["Connection stores ambient refusal for last sent stream<br/>and reports it to Station"] --> current
        current{"Refusal for current host, generation,<br/>destination and stream?"}
        current -->|no, including replaced stream| stale["Ignore for current listening session"]
        current -->|yes| kind{"How does the live capture handle this refusal?"}
        kind -->|transient| stored{"Does the next send observe this stored refusal?"}
        stored -->|no matching send| idle["No retry clock starts from this notice"]
        stored -->|yes| eligible{"Same live session and streamer,<br/>outside transport restoration?"}
        eligible -->|yes| budget{"Retry left after checking the quiet period?"}
        eligible -->|no| stationOther
        budget -->|no| stopped["End listening, retries exhausted"]
        budget -->|yes| delay["Back off 1, 3 or 10 s"]
        delay -->|same live run, renewal succeeds| renew["Same capture, new stream ID<br/>sequence zero with resume flag"]
        delay -->|otherwise| abandoned["No renewal of this stream"]
        kind -->|terminal refusal on live stream| terminal["Stop for policy, moved or other host refusal"]
        stationOther["(other outcomes: see source / inferred)"]
    end
    subgraph host["haild"]
        direction TB
        newrun["Admit new stream and construct child"]
        newrun -->|registered| install["Read child stdout"]
        newrun -->|otherwise| startOther["(other outcomes: see source / inferred)"]
        reload{"S13 Reload claim granted?"}
        reload -->|no| unswapped["Return without replacing run"]
        reload -->|yes| built{"Replacement constructed?"}
        built -->|no| unswapped
        built -->|yes| swap{"Swap still permitted?"}
        swap -->|no| reap["Reap unused replacement"]
        swap -->|yes| install
        install --> finish{"Consumer reaches EOF without an earlier error?"}
        finish -->|no| hostOther["(other outcomes: see source / inferred)"]
        finish -->|yes| eof{"Admitted terminal before EOF?"}
        eof -->|none| missing["K08 input invalidLifecycle"]
        eof -->|error after started| error["K09 input producerFailed"]
        eof -->|stopped or cancelled after started| clean["Check privacy proof and collect child status"]
        missing --> ended["Log ambient_ended with result<br/>A recorded privacy refusal takes precedence"]
        error --> ended
        clean --> ended
        hostOther --> ended
        ended --> notify{"Eligible to report to originating peer?"}
        notify -->|no| quiet["Host log only"]
        notify -->|yes| notice["Attempt ambient stopped notice<br/>Clean active exit: listener exited"]
        reset["S14 Daemon restart clears router state"]
    end
    subgraph child["RightyO child"]
        direction TB
        config{"Configuration passes validation?"}
        config -->|no| early["Setup error, exit 2 before started"]
        config -->|yes| runtime["Start controller and drain events"]
        runtime -->|still running| listen["Continue reading PCM"]
        runtime -->|valid terminal then EOF| done["Stopped, cancelled or error"]
        runtime -->|EOF without a terminal| crash["No complete lifecycle on stdout"]
    end
    start -->|initial stream| newrun
    renew -->|automatic resume, admission in §4| newrun
    notice -->|ambient error received for last sent stream| received
    host <-->|spawn or replace / stdout events then EOF| child
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| **K08 · Invalid config / missing lifecycle** | Before spawn, unsafe executable/ancestry or unreadable/nonregular config gives a host refusal such as `child unsafeConfig`. After spawn, RightyO loads the JSON and validates options/assets. `conversation.window_ms` must be 1,000–120,000. #1483 identifies an out-of-range value in one restart burst. Setup failure prints to child stderr and exits **2 before started**. EOF without a terminal event maps to `input invalidLifecycle`. A crash after started but before terminal can produce the same mapping. It does not identify the offending setting. [HS #1483][hs1483] | H09–H10, H12, H15, R01 · `RightyoChildSupport.swift:54`, `tool.py:322`, `prototype.py:407`, `contracts.py:566`, `cli.py:502`, `RightyoInputConsumer.swift:714`, `RightyoAmbientPipeline.swift:336` |
| **K09 · Producer failure after startup** | Once started, a processor failure can emit `session.error` and exit 2. An input overrun discards the unfinished tail and converts an otherwise stopped or cancelled terminal to an error. On a valid error terminal, `finish()` throws `producerFailed`. Protocol or dispatch errors can throw earlier. Privacy-proof failure has its own refusal. After an admitted stopped/cancelled terminal and EOF, haild collects the exit status. A still-active child exit can still end the stream. #1483 recorded both error names. The config incident establishes the cause of one burst only. [HS #1483][hs1483] | R01–R02, H12–H17 · `prototype.py:1601`, `prototype.py:2396`, `tool.py:435`, `RightyoInputConsumer.swift:876`, `RightyoInputConsumer.swift:715`, `RightyoAmbientPipeline.swift:337`, `WebSocketListener.swift:2038` |
| Retry and **K01** | haild logs `ambient_ended` on clean and failed runs. A clean end after the stream has already ended needs no notice. If the clean run still owns the active stream and the target session is unchanged, haild reports `ambient stopped: listener exited` to the originating peer. Replaced or already-reported runs skip notification, as does a missing listener. The connection associates an ambient refusal with its last sent stream. Station ignores a stale notice for a replaced stream. For a current `not_allowed: ambient stopped:` refusal, backoff begins only when the next audio send observes the stored error. With no such send, the notice alone starts no retry. Ordinary backoff also requires the same live session outside a pending transport restore. On successive recoveries Station waits **1, 3, 10 s**. If the same capture is still live, it opens a new stream ID with `isResume=true` and sequence zero. The budget resets after 120 s since the last recovery. Exhaustion ends listening. Each new child can reject the same file. Compare the device's `ambient_start` with host `ambient_started` / `ambient_ended` and actual child finals. [HS #1483][hs1483] | I13, H15–H17 · `WebSocketListener.swift:568`, `WebSocketListener.swift:2058`, `WebSocketListener.swift:2073`, `HostConnectionStore.swift:1416`, `HostConnectionStore.swift:1423`, `HostConnectionStore.swift:1453`, `HostConnectionStore.swift:1729`, `HostConnection+Protocol.swift:116`, `HostConnection+Protocol.swift:161`, `AmbientAudioStreamer.swift:381`, `AmbientReconnectAcceptanceOrderingTests.swift:50` |
| **S13 · Replacement loses a pending turn or fails immediately** | `haild ambient reload` requires an active run and capacity. Construct first, retaining stream, selected target and binding. On construction failure log `ambient_reload_refused` and leave a still-active predecessor running. Recheck identity/capacity under lock before swap. A lost race reaps the unused child. Success logs `ambient_reloaded` then `ambient_started` for the replacement and retires the old child. A new child session rereads the same file. Pending audio, engagement and uncompleted work can be lost at the boundary. Host path checks do not parse the child schema before swap. [HS #405][hs405], [HS #1483][hs1483] | H09, H15–H17 · `WebSocketListener.swift:1685`, `WebSocketListener.swift:1807`, `WebSocketListener.swift:2134`, `WebSocketListener.swift:2147`, `WebSocketListener.swift:2169`, `RightyoAmbientPipeline.swift:286`, `tool.py:322` |
| **S14 · State absent after daemon restart** | A new router has no previous children, sockets, binding for the active stream, privacy parks/overflow or engagement. Station may reconnect, reselect and reassert its own privacy (§4). [HS #1483][hs1483] | D03, D12 · `WebSocketListener.swift:845`, `WebSocketListener.swift:1133`, `WebSocketListener+PrivacyPark.swift:7`, `AmbientListeningReconnect.swift:401`, `AmbientListeningReconnect.swift:414` |

## 8. Acknowledgement, reply playback and echo

The short host clip and the target's reply have independent admission and timing. Both can reach the same output and affect the next captured turn. The feedback arrow below starts the next trip through §1.

```mermaid
flowchart LR
    subgraph mac["Mac capture"]
        direction TB
        observe["Observe activity and onset on original PCM"] --> talk{"Local Talk capture or its tail?"}
        talk -->|yes| zeros["Forward zeros"]
        talk -->|no| playing{"Audible reply or its tail?"}
        playing -->|no| pcm["Forward original PCM"]
        playing -->|yes| mask{"Reply masking enabled or no<br/>effective in-graph echo cancellation?"}
        mask -->|yes| zeros
        mask -->|no| pcm
        second["K10 Talk on another station<br/>can capture the same speech"]
        mobile["Mobile only: K11 route change<br/>K12 recovery controls inaccessible"]
    end
    subgraph host["haild"]
        direction TB
        heard{"S15 Heard words match<br/>recent reply audio or confirmation?"}
        heard -->|yes| drop["Drop echo"]
        heard -->|no| route["Continue privacy, local control and routing checks"]
        pool{"Eligible ack callback and clip?<br/>Try named or remembered pool, then default if absent"}
        pool -->|no| silence["No clip sent"]
        pool -->|yes| attempt{"Result of sending ordinary clip?"}
        attempt -->|sent| queue["Host reports transport success"]
        attempt -->|no_connection, not_ready, refused or suppressed_privacy| noClip["No successful clip delivery"]
    end
    subgraph child["RightyO child"]
        direction TB
        gate{"K13 Ack gating configured?"}
        gate -->|no| legacy["Omit flag, legacy host eligibility"]
        gate -->|yes| flag{"Name or score passes<br/>and no pending ack covering turn start?"}
        flag -->|yes| ack["Request: acknowledge=true"]
        flag -->|no| skip["Request: acknowledge=false"]
    end
    subgraph dispatch["dispatch"]
        direction TB
        hand["Unrouted: schedule eligible ack before adapter attempt<br/>Routed: schedule it only after handoff"]
        hand -->|committed owner and later correlated reply| response["Offer reply to its owner"]
        legacyReply["Requestless target reply"] --> fallback["Host resolves recipient under fallback policy"]
        hand -->|other handoff or reply outcomes| handOther["(other outcomes: see source / inferred)"]
    end
    subgraph reply["reply"]
        direction TB
        play{"Does Station start playback?"}
        play -->|yes| player["Play ack or reply<br/>K14 Can overlap next owner turn"]
        play -->|no S16| bad["(other outcomes: see source / inferred)"]
    end
    mac -->|subsequent mic audio| host
    host <-->|PCM and playback reports / request and ack flag| child
    host <-->|public request / ack at handoff boundary| dispatch
    %% Keep the child lane before dispatch in this feedback loop.
    child ~~~ dispatch
    dispatch -->|target reply| reply
    host -->|eligible short clip| reply
    mac <-->|capture mixer / playback busy and tail| reply
```

| Point | Branch and evidence | Decision map and source |
|---|---|---|
| **K13 · Instant ack cannot be controlled in Station** | With child ack gating configured, a configured name or sufficient confidence qualifies. A direct request uses decision confidence. A follow-up uses P(attend) and can have its own stricter floor. A still-pending ack can suppress a second clip. Main omits the field when gating is absent. An absent field or a session without the advertised gate uses legacy eligibility. With the gate advertised, `acknowledge=false` skips the clip and the request can proceed. [HS #1465][hs1465], [RightyO #339][ry339] | `tool_events.py:4008`, `tool_events.py:4032`, `RightyoAmbientPipeline.swift:838`, `RightyoAmbientPipeline.swift:863`, `WebSocketListener.swift:1845` |
| Clip delivery | Haild rotates valid mono PCM16 WAVs from the named/remembered persona or default pool. No callback/library, no clip, changed target, absent peer, denied permit or privacy hold can leave the request silent. Reserved clips (privacy on/off/status, refusal, not-sent) use separate pools. Unrouted acknowledgement is scheduled before the adapter attempt. An input-pending refusal can follow it with a refusal notice and then a not-sent clip. Routed acknowledgement waits for handoff. `ambient_acknowledged outcome=sent` records host transport success. | H19, R22 · `AmbientAcknowledgement.swift:108`, `AmbientAcknowledgement.swift:216`, `RightyoAmbientPipeline.swift:45`, `RightyoAmbientPipeline.swift:883`, `WebSocketListener.swift:1848`, `WebSocketListener+Acknowledgement.swift:44`, `RightyoInputConsumer.swift:1079` |
| **S16 · Reply sent but no audible answer** | Correlated publication needs an eligible owning peer. When requestless fallback is enabled, haild first tries a reply’s pinned peer or the target’s current last-input peer. Haild refuses the reply if its pinned peer is unavailable. Without a usable last-input route or pin, one eligible selector qualifies. Among multiple selectors the active ambient peer must be one of them. With no eligible selector the reply is refused. Recheck selection, privacy and stop fences. For incoming reply audio, Station skips frame IDs among the last 1,024 remembered. Reuse after eviction must pass the remaining checks. Station checks descriptor, format and sequence, buffers audio and starts contiguous segments from the queue head. A pause, mute, Talk hold, route/engine error, missing first audio, missing final or underrun can delay or lose playback. Compare host admission with device `reply_playback_start/end/error`. End gap counters measure underruns. Only a physical observation establishes audibility. [HS #1455][hs1455], [HS #1483][hs1483] | P03–P04, P06, P11 · `HostReplyDelivery.swift:1516`, `HostReplyDelivery.swift:1603`, `HostReplyDelivery.swift:1659`, `HostReplyDelivery.swift:1698`, `HostConnection+Protocol.swift:125`, `ReplyPlaybackController.swift:128`, `ReplyPlaybackController+Presentation.swift:171`, `PCM16AudioPlayer.swift:162`, `ReplyPlayoutBuffer.swift:56`, `ReplyPlaybackController+Idle.swift:97`, `DeviceDiagnostics.swift:388` |
| **K14 · Reply starts while the owner is speaking** | #1457 records an early endpoint, multiple fragment requests and an ordinary reply playing over a later fragment. While playing and for the default **400 ms** tail, Mac plain capture masks the mic. The activity and onset detectors see the original buffer. The guard then zeroes its samples before conversion and preserves stream timing. Tap-to-talk and its tail always mask locally. With effective in-graph echo cancellation on mobile and masking disabled, live speech can pass. Segment-boundary yield has its own timing/eligibility checks. [HS #1457][hs1457], [RightyO #107][ry107] | R03, R05–R08, I04–I05, P09 · `StationPlatform.swift:79`, `live_audio.py:1977`, `AmbientReplyEchoGuard.swift:20`, `AmbientReplyEchoGuard.swift:343`, `AmbientReplyEchoGuard.swift:605`, `AmbientReplyEchoGuard.swift:669`, `ReplyPlaybackController+Segments.swift:91` |
| **S15 · Echo leaks through or real speech is masked/matched** | The device mask can erase an overlapping owner turn. With reply controls enabled, haild can translate a current device playback start/end/error diagnostic into a child playback phase (error maps to ended). A request-scoped outcome governs the conversation once that reporting is active. Separately, child self-voice needs configured reply-window/echo evidence. Host-reported playback overlap excludes some presence candidates. Independently, haild drops a formed request if its heard words match recent reply audio (at least 5 words and 85% adjacent-pair overlap). An eligible sent confirmation recorded with its text can match an exact normalized phrase during playout plus 4 s. Missing text, short/mixed echoes or insufficient self evidence can escape. An owner repeating a reply could match. These are possible causes of missed or phantom turns. [RightyO #340][ry340], [HS #1483][hs1483] | P09–P10, R12, R14 · `self_voice.py:248`, `tool_events.py:2543`, `tool_events.py:3102`, `WebSocketListener.swift:1053`, `RightyoInputConsumer.swift:437`, `RightyoInputConsumer.swift:639`, `RightyoAmbientPipeline.swift:699`, `RightyoAmbientPipeline.swift:812` |
| **K10 · A second mic still captures** | Tap-to-talk on one device while another streams ambient produced two captures. A local Talk mask affects only that device's buffers. Fresh ambient takeover and automatic resume have distinct admission rules. Compare the two capture paths and the host's moved-stream outcome before attributing a duplicate to ASR. [HS #1433][hs1433], [HS #1439][hs1439] | D07, P09 · `Apps/Hail-iOS/StationTalkSession.swift:16`, `AmbientReplyEchoGuard.swift:97`, `AmbientAudioGate.swift:415`, `AmbientHandoff.swift:19` |
| **K11 · Mobile headset change stops capture and reply** | In #1455 connecting AirPods mid-session ended iPhone capture (`ended_by_system`) and the playing reply failed (`playback_failed`). The reply was lost and Ambient stayed off until a manual restart. A separate trace in the same issue found playback stayed on the speaker after capture started there in voice-processing mode. Station samples the output route when it constructs capture. Headset output can coexist with a built-in mic. Compare route changes, capture mode, `ended_by_system` and player error. [HS #1455][hs1455], [HS #1429][hs1429] | I01–I07, P04, P06 · `AmbientCaptureMode.swift:39`, `AmbientCaptureMode.swift:62`, `Capture.swift:359`, `ManagedAudioSession+BluetoothHFP.swift:30` |
| **K12 · Recovery controls inaccessible** | The mobile More menu could leave route and listening controls inaccessible before the owner could make a new capture or route choice. [HS #1454][hs1454] | `Apps/Hail-iOS/StationTalkDock.swift:44`, `RootView+StationScreen.swift:91` |

[hs-main]: https://github.com/mickdarling/hailing-station/tree/c36e14977d7f5a1c4dee8ff520577519db3c076e
[ry-main]: https://github.com/mickdarling/rightyo/tree/f13478021bf387e9fcfdcf7ddc7a65ec61402422
[decision-map]: https://github.com/mickdarling/hailing-station/blob/c36e14977d7f5a1c4dee8ff520577519db3c076e/docs/audio-decision-map.md
[hs405]: https://github.com/mickdarling/hailing-station/issues/405
[hs636]: https://github.com/mickdarling/hailing-station/issues/636
[hs735]: https://github.com/mickdarling/hailing-station/issues/735
[hs894]: https://github.com/mickdarling/hailing-station/issues/894
[hs904]: https://github.com/mickdarling/hailing-station/issues/904
[hs941]: https://github.com/mickdarling/hailing-station/issues/941
[hs1429]: https://github.com/mickdarling/hailing-station/issues/1429
[hs1433]: https://github.com/mickdarling/hailing-station/issues/1433
[hs1439]: https://github.com/mickdarling/hailing-station/issues/1439
[hs1440]: https://github.com/mickdarling/hailing-station/issues/1440
[hs1454]: https://github.com/mickdarling/hailing-station/issues/1454
[hs1455]: https://github.com/mickdarling/hailing-station/issues/1455
[hs1456]: https://github.com/mickdarling/hailing-station/issues/1456
[hs1457]: https://github.com/mickdarling/hailing-station/issues/1457
[hs1465]: https://github.com/mickdarling/hailing-station/issues/1465
[hs1483]: https://github.com/mickdarling/hailing-station/issues/1483
[ry107]: https://github.com/mickdarling/rightyo/issues/107
[ry332]: https://github.com/mickdarling/rightyo/issues/332
[ry334]: https://github.com/mickdarling/rightyo/issues/334
[ry339]: https://github.com/mickdarling/rightyo/issues/339
[ry340]: https://github.com/mickdarling/rightyo/issues/340
[ry340-status]: https://github.com/mickdarling/rightyo/issues/340#issuecomment-7228072127
[ry342]: https://github.com/mickdarling/rightyo/issues/342
[ry343]: https://github.com/mickdarling/rightyo/issues/343
[ry344]: https://github.com/mickdarling/rightyo/issues/344
[ry345]: https://github.com/mickdarling/rightyo/issues/345
[ry346]: https://github.com/mickdarling/rightyo/issues/346
[ry347]: https://github.com/mickdarling/rightyo/issues/347
[ry348]: https://github.com/mickdarling/rightyo/issues/348
[ry349]: https://github.com/mickdarling/rightyo/issues/349
[ry350]: https://github.com/mickdarling/rightyo/issues/350
