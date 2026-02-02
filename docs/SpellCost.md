# Spell Cost Function Specification (Mana + Upkeep)

**Status:** Draft v0.9  
**Goal:** Compute a fair, gameable (in the good sense), abuse-resistant mana cost for arbitrarily-defined “spells” whose internal behavior may be AI-generated and unbounded.

This spec defines:
- A **declared effect envelope** required for any spell to run
- A **static (cast) mana cost**
- A **dynamic (runtime) upkeep cost** based on measured impact
- **Safety limits** and shutdown behavior
- Reference formulas, constants, and examples

---

## 0. Design Principles

1. **Price measurable consequences, not intent.**  
   We cost *reach, persistence, privilege, and observed impact*.

2. **Predictable to players.**  
   Most costs are derived from visible spell parameters.

3. **Self-correcting at runtime.**  
   If a spell is more impactful than expected, upkeep rises automatically.

4. **Hard safety rails.**  
   Anything outside declared bounds is blocked or forces envelope expansion (which increases cost).

---

## 1. Definitions

### 1.1 Spell
A spell is a server-authoritative program (or program-like behavior) that may read and/or modify world state and optionally persist as an ongoing effect.

### 1.2 Effect Envelope (Required Declaration)
Every spell must declare an **Effect Envelope** (EE) before it can be cast. The EE is a contract: the spell may not exceed it.

The EE is composed of:
- **Scope** (spatial + entity reach)
- **Duration** (how long effect persists)
- **Frequency** (how often it executes)
- **Capabilities** (what kinds of world state it can touch)
- **Targeting** (players/NPCs/tiles/chunks)
- **Reversibility** (how undoable changes are)

### 1.3 Mana Types
- **Cast Mana (M_cast):** one-time cost at activation.
- **Upkeep Mana (M_upkeep):** continuous cost over time (per tick or per second).
- **Mana Bankruptcy:** if upkeep cannot be paid, the spell is throttled/shut down (see §7).

---

## 2. Required Data Schema (Effect Envelope)

Represented as JSON-like structure (names are normative; serialization format is implementation choice):

```json
{
  "version": "1.0",
  "scope": {
    "shape": "sphere|box|cone|path|global",
    "radius_m": 12.0,
    "volume_m3": 7238.0,
    "max_chunks": 2,
    "max_tiles": 300,
    "max_entities": 25,
    "max_players": 0
  },
  "duration": {
    "mode": "instant|timed|persistent",
    "seconds": 10.0,
    "max_seconds": 60.0
  },
  "frequency": {
    "mode": "one_shot|tick|event",
    "hz": 2.0,
    "max_hz": 10.0
  },
  "capabilities": {
    "read_world": true,
    "write_world": false,
    "spawn_entities": false,
    "delete_entities": false,
    "modify_terrain": false,
    "modify_inventory": false,
    "modify_stats": true,
    "network_emit": true,
    "cross_chunk": false
  },
  "reversibility": {
    "class": "fully_reversible|time_reversible|partially_reversible|irreversible",
    "undo_window_s": 30.0
  },
  "tags": {
    "pvp_relevant": false,
    "economy_relevant": false
  }
}
