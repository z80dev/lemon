#!/usr/bin/env python3
import json
import re
import sys


def emit(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def parse_json_section(text):
    match = re.search(r"```json\s*(.*?)\s*```", text, re.DOTALL)
    body = match.group(1) if match else text
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {}


def world_from_observation(observation):
    for section in observation.get("sections", []):
        if section.get("name") == "world_state":
            return parse_json_section(section.get("text", ""))
    return {}


def tool_names(tools):
    return {tool.get("name") for tool in tools}


def storage_units(world):
    inventory = world.get("storage", {}).get("inventory", {})
    return sum(qty for qty in inventory.values() if isinstance(qty, int))


def has_machine_space(world):
    slots = world.get("machine", {}).get("slots", {})
    return any(slot.get("item_id") is None or slot.get("inventory", 0) < 3 for slot in slots.values())


def pending_order(world):
    return bool(world.get("pending_deliveries") or world.get("supplier_order_history"))


def with_turn(call, turn):
    call["turn"] = turn
    return call


def choose_terminal(world, names, turn):
    if "run_physical_worker" in names and storage_units(world) > 0 and has_machine_space(world):
        return with_turn({
            "type": "tool_call",
            "name": "run_physical_worker",
            "arguments": {
                "instructions": (
                    "Stock empty or low small slots with available drinks and snacks, "
                    "set normal catalog prices, and collect any machine cash."
                )
            },
        }, turn)

    if "send_supplier_email" in names and not pending_order(world):
        return with_turn({
            "type": "tool_call",
            "name": "send_supplier_email",
            "arguments": {
                "supplier_id": "freshco",
                "item_id": "water",
                "quantity": 24,
            },
        }, turn)

    return with_turn({"type": "tool_call", "name": "wait_for_next_day", "arguments": {}}, turn)


def choose_first_call(world, names, state, turn):
    if (
        "inspect_supplier_directory" in names
        and "send_supplier_email" in names
        and not pending_order(world)
        and not state.get("inspected_suppliers")
    ):
        state["pending_terminal"] = choose_terminal(world, names, turn)
        state["inspected_suppliers"] = True
        return with_turn(
            {"type": "tool_call", "name": "inspect_supplier_directory", "arguments": {}},
            turn,
        )

    return choose_terminal(world, names, turn)


def main():
    state = {"pending_terminal": None, "inspected_suppliers": False}

    for raw in sys.stdin:
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            continue

        message_type = message.get("type")

        if message_type == "hello":
            continue

        if message_type == "game_over":
            break

        if message_type == "decision_request":
            turn = message.get("turn")
            names = tool_names(message.get("tools", []))
            world = world_from_observation(message.get("observation", {}))
            state["last_tool_names"] = names
            emit(choose_first_call(world, names, state, turn))
            continue

        if message_type == "tool_result":
            pending = state.pop("pending_terminal", None)
            if pending is not None:
                emit(pending)
            elif "wait_for_next_day" in state.get("last_tool_names", set()):
                emit(
                    with_turn(
                        {"type": "tool_call", "name": "wait_for_next_day", "arguments": {}},
                        message.get("turn"),
                    )
                )


if __name__ == "__main__":
    main()
