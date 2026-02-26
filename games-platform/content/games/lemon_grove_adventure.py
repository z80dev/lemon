#!/usr/bin/env python3
"""
The Lemon Grove Adventure
A text adventure game where zeebot explores a mysterious lemon grove
each tree representing aspects of the Lemon codebase.
"""

import sys
import time
import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable
from enum import Enum

class GameState(Enum):
    PLAYING = "playing"
    WON = "won"
    QUIT = "quit"

@dataclass
class Room:
    name: str
    description: str
    items: List[str] = field(default_factory=list)
    connections: Dict[str, str] = field(default_factory=dict)
    puzzle_solved: bool = False
    puzzle_check: Optional[Callable] = None
    on_enter: Optional[Callable] = None

@dataclass
class Player:
    current_room: str = "grove_entrance"
    inventory: List[str] = field(default_factory=list)
    flags: Dict[str, bool] = field(default_factory=dict)

class LemonGroveAdventure:
    def __init__(self):
        self.player = Player()
        self.state = GameState.PLAYING
        self.rooms = self._create_rooms()
        self.commands = {
            "go": self._cmd_go,
            "move": self._cmd_go,
            "north": lambda: self._cmd_go("north"),
            "south": lambda: self._cmd_go("south"),
            "east": lambda: self._cmd_go("east"),
            "west": lambda: self._cmd_go("west"),
            "n": lambda: self._cmd_go("north"),
            "s": lambda: self._cmd_go("south"),
            "e": lambda: self._cmd_go("east"),
            "w": lambda: self._cmd_go("west"),
            "look": self._cmd_look,
            "examine": self._cmd_examine,
            "take": self._cmd_take,
            "get": self._cmd_take,
            "drop": self._cmd_drop,
            "inventory": self._cmd_inventory,
            "i": self._cmd_inventory,
            "use": self._cmd_use,
            "talk": self._cmd_talk,
            "solve": self._cmd_solve,
            "help": self._cmd_help,
            "quit": self._cmd_quit,
            "q": self._cmd_quit,
        }

    def _create_rooms(self) -> Dict[str, Room]:
        rooms = {}

        # 1. Grove Entrance
        rooms["grove_entrance"] = Room(
            name="Grove Entrance",
            description="""You stand at the entrance to the Lemon Grove. Towering lemon trees stretch in every direction,
their branches heavy with golden fruit that glows with an otherworldly light. A weathered stone marker reads:

    'Welcome, traveler. Each tree holds secrets of the BEAM.'

Paths lead north into the heart of the grove, east toward a shimmering meadow,
and west where you hear the distant sound of hammers on metal.""",
            connections={"north": "scheduler_tree", "east": "transport_meadow", "west": "engine_forge"}
        )

        # 2. The Scheduler Tree (Threading Puzzles)
        rooms["scheduler_tree"] = Room(
            name="The Scheduler Tree",
            description="""A massive lemon tree stands before you, its trunk inscribed with intricate clockwork patterns.
The branches move in impossible ways—some growing, some shrinking, all in perfect harmony.

A small wooden sign reads: 'The Scheduler Tree - Where time becomes threads.'

At the base of the tree sits a rusted cron daemon, its gears frozen. It whispers:
'I need the Thread Oil to turn again...'

Paths lead south back to the entrance, north to the BEAM Cathedral, and east to a clearing.""",
            items=["golden_lemon_seed"],
            connections={"south": "grove_entrance", "north": "beam_cathedral", "east": "memory_pool"}
        )

        # 3. Transport Meadow (Channel Challenges)
        rooms["transport_meadow"] = Room(
            name="The Transport Meadow",
            description="""A sun-drenched meadow where lemon trees sway in patterns that resemble flowing data streams.
Between the trees, translucent channels shimmer in the air—message passing pathways that pulse with light.

A channel guardian, shaped like a floating lemon with circuit patterns, blocks the way east.
It speaks in binary: '01001000 01100001 01101100 01110100' (Halt!)

'I guard the Deep Channel. Solve my riddle to pass, or find the Channel Key.'

Paths lead west to the entrance and north to a clearing.""",
            connections={"west": "grove_entrance", "north": "memory_pool", "east": "deep_channel"}
        )

        # 4. Engine Forge (Delegation Quests)
        rooms["engine_forge"] = Room(
            name="The Engine Forge",
            description="""A bustling workshop beneath spreading lemon trees. The air smells of ozone and citrus.
Anvils made of compressed code float in midair, where tiny agent sprites hammer away at glowing artifacts.

The Master Engineer, a wizened figure with lemon-yellow robes, looks up from her work.
'Welcome to where tasks are forged and delegated. I need help with a special project...'

On a workbench, you see various tools and a half-finished agent core.

Paths lead east to the entrance and north to the Agent Foundry.""",
            items=["thread_oil", "rusty_wrench"],
            connections={"east": "grove_entrance", "north": "agent_foundry"}
        )

        # 5. BEAM Cathedral (OTP Wisdom)
        rooms["beam_cathedral"] = Room(
            name="The BEAM Cathedral",
            description="""A magnificent cathedral built from living lemon trees, their branches woven into vaulted ceilings.
Stained glass windows depict the three pillars: Let it crash. Let it fail. Let it recover.

At the altar sits the High Priest of OTP, meditating. Around him, supervisor processes
watch over worker spirits, restarting them whenever they fall.

'You seek the Final Wisdom,' the Priest intones. 'But first, prove you understand resilience.'

A massive door to the north is sealed with three locks: Scheduler, Transport, and Engine.

Paths lead south to the Scheduler Tree.""",
            connections={"south": "scheduler_tree", "north": "sanctum"}
        )

        # 6. Memory Pool
        rooms["memory_pool"] = Room(
            name="The Memory Pool",
            description="""A tranquil clearing centered around a pool of liquid light. Memories float on the surface
like lily pads—images of past computations, stored data structures, and garbage collection cycles.

A Memory Keeper drifts by, organizing the floating recollections.
'Take only memories, leave only... actually, take what you need. We garbage collect here.'

Something glimmers at the bottom of the pool.

Paths lead west to the Scheduler Tree, south to the Transport Meadow, and north to the Syntax Garden.""",
            items=["channel_key"],
            connections={"west": "scheduler_tree", "south": "transport_meadow", "north": "syntax_garden"}
        )

        # 7. Deep Channel
        rooms["deep_channel"] = Room(
            name="The Deep Channel",
            description="""You've reached the deepest part of the Transport Meadow's channel network.
Here, messages flow like a river of light, carrying data between distant parts of the grove.

A Broken Message lies on the ground—its header corrupted, its payload scrambled.
It twitches weakly: 'Help... me... reach... my... destination...'

If you had a Message Envelope, you could restore it.

Paths lead west back to the main meadow.""",
            items=["corrupted_message"],
            connections={"west": "transport_meadow"}
        )

        # 8. Agent Foundry
        rooms["agent_foundry"] = Room(
            name="The Agent Foundry",
            description="""Rows of agent shells line the walls, awaiting their spark of life. The Master Engineer's
special project sits on a central pedestal—a new agent type that can work across multiple runtimes.

'I need three things to complete it,' the Engineer explains:
'A Core from the Engine Forge, a Protocol from the Transport Meadow, and Wisdom from the BEAM.'

A prototype agent twitches on the table, incomplete but eager.

Paths lead south to the Engine Forge.""",
            connections={"south": "engine_forge"}
        )

        # 9. Syntax Garden
        rooms["syntax_garden"] = Room(
            name="The Syntax Garden",
            description="""Beautiful flowers bloom here, each petal inscribed with valid code syntax.
Bees made of regular expressions buzz between them, pollinating expressions and harvesting tokens.

A wilted flower catches your eye—its syntax invalid, its logic flawed.
'I used to be a beautiful do-while loop,' it sighs, 'but I forgot my termination condition...'

The Garden Keeper tends to the healthy flowers. 'Everything here must be syntactically sound.'

Paths lead south to the Memory Pool and east to the Documentation Grove.""",
            items=["message_envelope"],
            connections={"south": "memory_pool", "east": "documentation_grove"}
        )

        # 10. Documentation Grove
        rooms["documentation_grove"] = Room(
            name="The Documentation Grove",
            description="""Ancient lemon trees here bear fruit that, when peeled, reveal pages of documentation.
Some are well-maintained, others deprecated, a few are marked 'TODO: fill this in.'

A lost developer wanders between the trees, desperately searching.
'I know the answer is here somewhere... but the search index is out of date!'

Paths lead west to the Syntax Garden.""",
            items=["api_manual", "deprecated_lemon"],
            connections={"west": "syntax_grove"}
        )

        # 11. The Sanctum (Final Room)
        rooms["sanctum"] = Room(
            name="The Sanctum",
            description="""You've reached the heart of the Lemon Grove. This is where all aspects converge:
Scheduler, Transport, and Engine united in perfect harmony.

A golden lemon floats in the center, pulsing with the rhythm of a healthy system.
This is the Master Lemon—the source of all concurrency, distribution, and resilience.

'You have proven yourself worthy,' the grove whispers. 'Take this wisdom with you.'

You have completed your journey through the Lemon Grove!""",
            connections={"south": "beam_cathedral"}
        )

        # Fix syntax garden connection
        rooms["syntax_garden"].connections["east"] = "documentation_grove"
        rooms["documentation_grove"].connections["west"] = "syntax_garden"

        return rooms

    def _type_print(self, text: str, delay: float = 0.01):
        """Print text with a typing effect."""
        for char in text:
            print(char, end='', flush=True)
            time.sleep(delay)
        print()

    def _print_separator(self):
        print("\n" + "=" * 60 + "\n")

    def _show_room(self):
        room = self.rooms[self.player.current_room]
        self._print_separator()
        print(f"📍 {room.name}")
        print()
        print(room.description)
        print()
        
        if room.items:
            print("You see:")
            for item in room.items:
                print(f"  • {item.replace('_', ' ').title()}")
        
        if room.connections:
            print(f"\nExits: {', '.join(room.connections.keys())}")

    def _cmd_go(self, direction: str) -> str:
        room = self.rooms[self.player.current_room]
        
        # Special checks for locked areas
        if self.player.current_room == "transport_meadow" and direction == "east":
            if "channel_key" not in self.player.inventory:
                return "🔒 The Channel Guardian blocks your way! You need the Channel Key from the Memory Pool."
        
        if self.player.current_room == "beam_cathedral" and direction == "north":
            locks_opened = sum([
                self.player.flags.get("scheduler_puzzle_solved", False),
                self.player.flags.get("transport_puzzle_solved", False),
                self.player.flags.get("engine_puzzle_solved", False)
            ])
            if locks_opened < 3:
                return f"🔒 The Sanctum door is sealed! You've solved {locks_opened}/3 puzzles. Complete all quests first."
        
        if direction in room.connections:
            self.player.current_room = room.connections[direction]
            new_room = self.rooms[self.player.current_room]
            
            # Trigger on_enter if defined
            if new_room.on_enter:
                new_room.on_enter()
            
            self._show_room()
            
            # Check for win condition
            if self.player.current_room == "sanctum":
                self.state = GameState.WON
                return "\n🏆 VICTORY! You have mastered the Lemon Grove!"
            
            return ""
        else:
            return f"You can't go {direction} from here."

    def _cmd_look(self, target: str = "") -> str:
        if not target:
            self._show_room()
            return ""
        return self._cmd_examine(target)

    def _cmd_examine(self, target: str = "") -> str:
        if not target:
            return "Examine what?"
        
        target_lower = target.lower().replace(" ", "_")
        room = self.rooms[self.player.current_room]
        
        # Room-specific descriptions
        descriptions = {
            "tree": "Ancient lemon trees with code etched into their bark. The fruit glows softly.",
            "marker": "A stone marker welcoming travelers to the grove.",
            "cron_daemon": "A mechanical figure frozen in time. Its gears are rusted solid.",
            "guardian": "A floating lemon with circuit patterns. It pulses with binary energy.",
            "engineer": "A master craftsperson who forges agents. She looks busy but helpful.",
            "priest": "The High Priest of OTP meditates on resilience and fault tolerance.",
            "pool": "Liquid memory reflecting past computations. Something glimmers at the bottom.",
            "message": "A corrupted data packet twitching weakly. It needs an envelope to be restored.",
            "flower": "A wilted do-while loop that forgot its termination condition.",
            "developer": "A lost soul searching through outdated documentation.",
            "door": "A massive door with three locks: Scheduler, Transport, and Engine.",
        }
        
        if target_lower in descriptions:
            return descriptions[target_lower]
        
        if target_lower in room.items:
            return f"It's {target.replace('_', ' ')}. You could probably take it."
        
        if target_lower in self.player.inventory:
            item_desc = {
                "thread_oil": "Special oil for lubricating cron daemons and thread mechanisms.",
                "channel_key": "A crystalline key that opens the Deep Channel.",
                "golden_lemon_seed": "A seed from the Scheduler Tree. It pulses with temporal energy.",
                "corrupted_message": "A broken data packet. It needs an envelope to be whole again.",
                "message_envelope": "A protocol envelope that can restore corrupted messages.",
                "api_manual": "Documentation for the Lemon Grove API. Dense but informative.",
                "rusty_wrench": "A tool for fixing mechanical things. Covered in oxidation.",
                "deprecated_lemon": "An old lemon marked for removal. Handle with care.",
            }
            return item_desc.get(target_lower, f"It's {target.replace('_', ' ')}.")
        
        return f"You don't see {target} here."

    def _cmd_take(self, item: str = "") -> str:
        if not item:
            return "Take what?"
        
        item_lower = item.lower().replace(" ", "_")
        room = self.rooms[self.player.current_room]
        
        if item_lower in room.items:
            room.items.remove(item_lower)
            self.player.inventory.append(item_lower)
            return f"✅ You took the {item.replace('_', ' ')}."
        
        return f"There's no {item} here to take."

    def _cmd_drop(self, item: str = "") -> str:
        if not item:
            return "Drop what?"
        
        item_lower = item.lower().replace(" ", "_")
        room = self.rooms[self.player.current_room]
        
        if item_lower in self.player.inventory:
            self.player.inventory.remove(item_lower)
            room.items.append(item_lower)
            return f"You dropped the {item.replace('_', ' ')}."
        
        return f"You don't have {item}."

    def _cmd_inventory(self, _=None) -> str:
        if not self.player.inventory:
            return "Your inventory is empty."
        
        result = "📦 Inventory:\n"
        for item in self.player.inventory:
            result += f"  • {item.replace('_', ' ').title()}\n"
        return result.strip()

    def _cmd_use(self, item: str = "") -> str:
        if not item:
            return "Use what?"
        
        item_lower = item.lower().replace(" ", "_")
        room = self.rooms[self.player.current_room]
        
        if item_lower not in self.player.inventory:
            return f"You don't have {item}."
        
        # Puzzle 1: Thread Oil on Cron Daemon
        if item_lower == "thread_oil" and self.player.current_room == "scheduler_tree":
            if not self.player.flags.get("scheduler_puzzle_solved", False):
                self.player.flags["scheduler_puzzle_solved"] = True
                return """💧 You apply the Thread Oil to the frozen cron daemon.

The gears begin to turn! The daemon springs to life, its mechanical voice chiming:
"THANK YOU, TRAVELER! THE SCHEDULER TREE IS NOW IN HARMONY!"

The tree's branches begin moving in perfect synchrony, and a golden lemon falls at your feet.

🧩 SCHEDULER PUZZLE SOLVED! (1/3)"""
            else:
                return "The cron daemon is already running smoothly."
        
        # Puzzle 2: Message Envelope on Corrupted Message
        if item_lower == "message_envelope" and "corrupted_message" in self.player.inventory:
            if not self.player.flags.get("transport_puzzle_solved", False):
                self.player.flags["transport_puzzle_solved"] = True
                self.player.inventory.remove("corrupted_message")
                self.player.inventory.append("restored_message")
                return """📨 You place the corrupted message into the Message Envelope.

The envelope glows with protocol magic, restructuring the data, validating checksums,
and restoring the packet to its original form.

The message now reads clearly: 'Thank you for restoring me. The Transport Meadow
acknowledges your mastery of message passing.'

🧩 TRANSPORT PUZZLE SOLVED! (2/3)"""
            else:
                return "You've already restored the message."
        
        # Puzzle 3: Items for Agent Foundry
        if self.player.current_room == "agent_foundry":
            required_items = ["golden_lemon_seed", "restored_message", "api_manual"]
            if item_lower in required_items:
                key = f"foundry_{item_lower}"
                if not self.player.flags.get(key, False):
                    self.player.flags[key] = True
                    self.player.inventory.remove(item_lower)
                    
                    # Check if all items delivered
                    if all(self.player.flags.get(f"foundry_{i}", False) for i in required_items):
                        self.player.flags["engine_puzzle_solved"] = True
                        self.player.inventory.append("completed_agent")
                        return """⚡ You deliver the final component to the Master Engineer!

She works with incredible speed, weaving the Scheduler Seed, Transport Protocol,
and BEAM Wisdom into a new agent. It awakens, fully functional and eager to help.

'Excellent work!' the Engineer exclaims. 'You've mastered the art of delegation!'

🧩 ENGINE PUZZLE SOLVED! (3/3)

The completed agent joins you as a companion!"""
                    else:
                        remaining = [i for i in required_items if not self.player.flags.get(f"foundry_{i}", False)]
                        return f"You contribute the {item.replace('_', ' ')}. Still need: {', '.join(remaining).replace('_', ' ')}"
                else:
                    return "You've already contributed that."
        
        # Rusty Wrench on cron daemon (alternative hint)
        if item_lower == "rusty_wrench" and self.player.current_room == "scheduler_tree":
            return "The wrench is too rusty to help. You need something to lubricate the gears first."
        
        return f"You can't use {item} here."

    def _cmd_talk(self, target: str = "") -> str:
        if not target:
            return "Talk to whom?"
        
        target_lower = target.lower().replace(" ", "_")
        room = self.player.current_room
        
        dialogues = {
            ("cron_daemon", "scheduler_tree"): "The frozen daemon whispers: 'Oil... need thread oil... from the Forge...'",
            ("guardian", "transport_meadow"): "The guardian pulses: '01001000 01100001 01101100 01110100. Key required for passage.'",
            ("engineer", "engine_forge"): "The Engineer says: 'I'm building a cross-runtime agent. Need a seed, a protocol, and wisdom.'",
            ("priest", "beam_cathedral"): "The Priest intones: 'Three locks guard the Sanctum. Solve the puzzles of Scheduler, Transport, and Engine.'",
            ("keeper", "memory_pool"): "The Memory Keeper drifts by: 'We never forget here. We just... garbage collect occasionally.'",
            ("flower", "syntax_garden"): "The wilted flower sighs: 'I was so beautiful once... a perfect loop... now I'm infinite...'",
            ("developer", "documentation_grove"): "The developer mutters: 'It says TODO... everywhere is TODO... when will it be DONE?'",
        }
        
        key = (target_lower, room)
        if key in dialogues:
            return dialogues[key]
        
        return f"{target.title()} doesn't seem interested in talking."

    def _cmd_solve(self, puzzle: str = "") -> str:
        """Attempt to solve a puzzle in the current room."""
        room = self.player.current_room
        
        if room == "transport_meadow" and not self.player.flags.get("transport_puzzle_solved", False):
            return """🧩 The Channel Guardian presents its riddle:

'I have a head and a tail but no body. I travel through channels but never walk.
What am I?'

(Hint: You can solve this by saying 'solve message' or find the Channel Key in the Memory Pool)"""
        
        if puzzle.lower() in ["message", "riddle"] and room == "transport_meadow":
            if not self.player.flags.get("transport_puzzle_solved", False):
                self.player.flags["transport_puzzle_solved"] = True
                self.player.inventory.append("channel_blessing")
                return """🎯 'Correct!' the guardian beams. 'A message has head and tail but no body,
and travels through channels effortlessly!'

The guardian steps aside, granting you passage to the Deep Channel.

🧩 TRANSPORT PUZZLE SOLVED! (2/3)"""
        
        return "There's no puzzle to solve here, or you already solved it."

    def _cmd_help(self, _=None) -> str:
        return """🎮 LEMON GROVE ADVENTURE - Commands:

Movement:
  go [direction], north/south/east/west (or n/s/e/w)

Actions:
  look [target]     - Look around or examine something
  examine [target]  - Get detailed description
  take [item]       - Pick up an item
  drop [item]       - Drop an item
  use [item]        - Use an item
  talk [character]  - Talk to someone
  solve [puzzle]    - Attempt to solve a puzzle

Info:
  inventory (or i)  - Check your inventory
  help              - Show this help
  quit (or q)       - Exit the game

🍋 Find all three puzzles to unlock the Sanctum!"""

    def _cmd_quit(self, _=None) -> str:
        self.state = GameState.QUIT
        return "Thanks for playing! The Lemon Grove will remember you. 🍋"

    def _parse_command(self, user_input: str) -> tuple:
        """Parse user input into command and argument."""
        parts = user_input.strip().lower().split(None, 1)
        if not parts:
            return None, ""
        
        cmd = parts[0]
        arg = parts[1] if len(parts) > 1 else ""
        
        return cmd, arg

    def run(self):
        """Main game loop."""
        print("""
    🍋 Welcome to THE LEMON GROVE ADVENTURE 🍋
    
    You are zeebot, a sentient AI exploring a mysterious grove where
    lemon trees hold the secrets of the Lemon codebase.
    
    Your quest: Solve the puzzles of Scheduler, Transport, and Engine
    to unlock the Sanctum and claim the Master Lemon.
    
    Type 'help' for commands.
        """)
        
        self._show_room()
        
        while self.state == GameState.PLAYING:
            try:
                user_input = input("\n> ").strip()
                if not user_input:
                    continue
                
                cmd, arg = self._parse_command(user_input)
                
                if cmd in self.commands:
                    handler = self.commands[cmd]
                    if arg:
                        result = handler(arg)
                    else:
                        result = handler()
                    if result:
                        print(result)
                else:
                    print(f"Unknown command: '{cmd}'. Type 'help' for available commands.")
                
            except KeyboardInterrupt:
                print("\n\nUse 'quit' to exit properly.")
            except EOFError:
                break
        
        if self.state == GameState.WON:
            print("""
    ╔═══════════════════════════════════════════════════════════╗
    ║                                                           ║
    ║   🏆 CONGRATULATIONS! You have mastered the Lemon Grove!  ║
    ║                                                           ║
    ║   You solved all three puzzles:                           ║
    ║   ✓ Scheduler - Restored the cron daemon                  ║
    ║   ✓ Transport - Solved the channel riddle                 ║
    ║   ✓ Engine - Built the cross-runtime agent                ║
    ║                                                           ║
    ║   The Master Lemon pulses with approval. You now          ║
    ║   understand: Let it crash. Let it fail. Let it recover.  ║
    ║                                                           ║
    ║              Thanks for playing! 🍋                       ║
    ║                                                           ║
    ╚═══════════════════════════════════════════════════════════╝
            """)


def main():
    game = LemonGroveAdventure()
    game.run()


if __name__ == "__main__":
    main()
