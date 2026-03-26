"""
Search the il2cpp_dump.json for types, fields, methods, and properties.

Usage:
    python il2cpp_search.py <command> <query> [options]

Commands:
    type <name>           Show full type info (fields, methods, properties, parent)
    field <name>          Search for fields by name across all types
    method <name>         Search for methods by name across all types
    enum <name>           Show enum values (name -> numeric value)
    parent <name>         Show the parent/inheritance chain for a type
    children <name>       Find types that inherit from the given type
    has-field <name>      Find types that have a field with the given name
    has-method <name>     Find types that have a method with the given name
    offset <type> <off>   Find what field is at a given offset in a type

Options:
    --exact               Exact match instead of substring
    --limit N             Max results (default: 20)
    --json                Output raw JSON
"""

import json
import sys
import os
import argparse
import re

DUMP_PATH = r"Q:\SteamLibrary\steamapps\common\Street Fighter 6\il2cpp_dump.json"

_data = None

def load_dump():
    global _data
    if _data is None:
        print(f"Loading dump (this takes a moment)...", file=sys.stderr)
        with open(DUMP_PATH, "r") as f:
            _data = json.load(f)
        print(f"Loaded {len(_data)} types.", file=sys.stderr)
    return _data


def match(query, text, exact):
    if exact:
        return query == text
    return query.lower() in text.lower()


def cmd_type(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        if match(args.query, type_name, args.exact):
            found += 1
            print(f"\n{'='*70}")
            print(f"Type: {type_name}")
            print(f"  Address: {info.get('address', '?')}")
            print(f"  Parent:  {info.get('parent', 'none')}")
            print(f"  Size:    {info.get('size', '?')}")
            print(f"  Flags:   {info.get('flags', '')}")

            fields = info.get("fields", {})
            if fields:
                print(f"\n  Fields ({len(fields)}):")
                for fname, fdata in sorted(fields.items(), key=lambda x: x[1].get("offset_from_base", "0x0")):
                    offset = fdata.get("offset_from_base", "?")
                    ftype = fdata.get("type", "?")
                    flags = fdata.get("flags", "")
                    print(f"    {offset:>8s}  {ftype:<40s}  {fname}  [{flags}]")

            methods = info.get("methods", {})
            if methods:
                print(f"\n  Methods ({len(methods)}):")
                for mname, mdata in sorted(methods.items()):
                    ret = mdata.get("returns", {}).get("type", "void")
                    params = mdata.get("params", [])
                    param_str = ", ".join(f"{p['type']} {p['name']}" for p in params)
                    addr = mdata.get("function", "?")
                    print(f"    {addr:>16s}  {ret:<30s}  {mname}({param_str})")

            props = info.get("properties", {})
            if props:
                print(f"\n  Properties ({len(props)}):")
                for pname, pdata in sorted(props.items()):
                    getter = pdata.get("getter", "")
                    setter = pdata.get("setter", "")
                    gs = []
                    if getter: gs.append(f"get={getter}")
                    if setter: gs.append(f"set={setter}")
                    print(f"    {pname:<40s}  {', '.join(gs)}")

            if found >= args.limit:
                print(f"\n... (limited to {args.limit} results)")
                break
    if found == 0:
        print(f"No types matching '{args.query}'")


def cmd_field(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        for fname, fdata in info.get("fields", {}).items():
            if match(args.query, fname, args.exact):
                offset = fdata.get("offset_from_base", "?")
                ftype = fdata.get("type", "?")
                print(f"  {type_name}  +{offset}  {ftype}  {fname}")
                found += 1
                if found >= args.limit:
                    break
        if found >= args.limit:
            print(f"\n... (limited to {args.limit} results)")
            break
    if found == 0:
        print(f"No fields matching '{args.query}'")


def cmd_method(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        for mname, mdata in info.get("methods", {}).items():
            if match(args.query, mname, args.exact):
                ret = mdata.get("returns", {}).get("type", "void")
                addr = mdata.get("function", "?")
                params = mdata.get("params", [])
                param_str = ", ".join(f"{p['type']} {p['name']}" for p in params)
                print(f"  {type_name}::{mname}({param_str}) -> {ret}  @{addr}")
                found += 1
                if found >= args.limit:
                    break
        if found >= args.limit:
            print(f"\n... (limited to {args.limit} results)")
            break
    if found == 0:
        print(f"No methods matching '{args.query}'")


def cmd_enum(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        if not match(args.query, type_name, args.exact):
            continue
        parent = info.get("parent", "")
        if parent != "System.Enum":
            continue
        found += 1
        print(f"\n{'='*70}")
        print(f"Enum: {type_name}")
        backing = info.get("fields", {}).get("value__", {})
        print(f"  Backing type: {backing.get('type', '?')}")

        entries = []
        for fname, fdata in info.get("fields", {}).items():
            if fname == "value__":
                continue
            flags = fdata.get("flags", "")
            if "Literal" not in flags:
                continue
            val = fdata.get("default")
            if val is None:
                val = fdata.get("init_data_index", "?")
            entries.append((val, fname))

        entries.sort(key=lambda x: x[0] if isinstance(x[0], (int, float)) else 0)
        for val, name in entries:
            print(f"    {val:>6}  {name}")

        if found >= args.limit:
            print(f"\n... (limited to {args.limit} results)")
            break
    if found == 0:
        print(f"No enums matching '{args.query}'")


def cmd_parent(args):
    data = load_dump()
    for type_name, info in data.items():
        if match(args.query, type_name, args.exact):
            chain = [type_name]
            current = info
            while current.get("parent"):
                parent = current["parent"]
                chain.append(parent)
                current = data.get(parent, {})
            print(" -> ".join(chain))
            return
    print(f"Type '{args.query}' not found")


def cmd_children(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        parent = info.get("parent", "")
        if match(args.query, parent, args.exact):
            print(f"  {type_name}  (parent: {parent})")
            found += 1
            if found >= args.limit:
                print(f"\n... (limited to {args.limit} results)")
                break
    if found == 0:
        print(f"No children of '{args.query}'")


def cmd_has_field(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        for fname in info.get("fields", {}):
            if match(args.query, fname, args.exact):
                print(f"  {type_name}  has field '{fname}'")
                found += 1
                break
        if found >= args.limit:
            print(f"\n... (limited to {args.limit} results)")
            break
    if found == 0:
        print(f"No types with field matching '{args.query}'")


def cmd_has_method(args):
    data = load_dump()
    found = 0
    for type_name, info in data.items():
        for mname in info.get("methods", {}):
            if match(args.query, mname, args.exact):
                print(f"  {type_name}  has method '{mname}'")
                found += 1
                break
        if found >= args.limit:
            print(f"\n... (limited to {args.limit} results)")
            break
    if found == 0:
        print(f"No types with method matching '{args.query}'")


def cmd_offset(args):
    data = load_dump()
    target_offset = args.query  # e.g. "0xb8"
    type_query = args.type_name
    for type_name, info in data.items():
        if match(type_query, type_name, args.exact):
            print(f"Type: {type_name}")
            for fname, fdata in sorted(info.get("fields", {}).items(),
                                        key=lambda x: x[1].get("offset_from_base", "0x0")):
                offset = fdata.get("offset_from_base", "0x0")
                if offset == target_offset:
                    ftype = fdata.get("type", "?")
                    print(f"  MATCH: +{offset}  {ftype}  {fname}")
                    return
            # If exact offset not found, show nearby
            print(f"  No field at exact offset {target_offset}. Nearby fields:")
            for fname, fdata in sorted(info.get("fields", {}).items(),
                                        key=lambda x: int(x[1].get("offset_from_base", "0x0"), 16)):
                offset = fdata.get("offset_from_base", "0x0")
                ftype = fdata.get("type", "?")
                print(f"    +{offset}  {ftype}  {fname}")
            return
    print(f"Type '{type_query}' not found")


def main():
    parser = argparse.ArgumentParser(description="Search SF6 il2cpp_dump.json")
    parser.add_argument("--exact", action="store_true", help="Exact match")
    parser.add_argument("--limit", type=int, default=20, help="Max results")

    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("type", help="Show full type info")
    p.add_argument("query")

    p = sub.add_parser("field", help="Search fields by name")
    p.add_argument("query")

    p = sub.add_parser("method", help="Search methods by name")
    p.add_argument("query")

    p = sub.add_parser("enum", help="Show enum values")
    p.add_argument("query")

    p = sub.add_parser("parent", help="Show inheritance chain")
    p.add_argument("query")

    p = sub.add_parser("children", help="Find child types")
    p.add_argument("query")

    p = sub.add_parser("has-field", help="Find types with a field")
    p.add_argument("query")

    p = sub.add_parser("has-method", help="Find types with a method")
    p.add_argument("query")

    p = sub.add_parser("offset", help="Find field at offset in a type")
    p.add_argument("type_name")
    p.add_argument("query", help="Offset like 0xb8")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    cmds = {
        "type": cmd_type,
        "field": cmd_field,
        "method": cmd_method,
        "enum": cmd_enum,
        "parent": cmd_parent,
        "children": cmd_children,
        "has-field": cmd_has_field,
        "has-method": cmd_has_method,
        "offset": cmd_offset,
    }

    cmds[args.command](args)


if __name__ == "__main__":
    main()
