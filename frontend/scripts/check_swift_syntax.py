"""Optional Windows syntax check; not an Apple SDK typecheck or build.

Install isolated parser wheels with:
python -m pip install --target frontend/.validation-tools tree-sitter==0.26.0 tree-sitter-swift==0.7.4
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".validation-tools"))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
failures = []
files = [p for folder in ["MovementForest", "MovementForestTests", "MovementForestUITests"] for p in (ROOT / folder).rglob("*.swift")]
for path in files:
    source = path.read_bytes()
    tree = parser.parse(source)
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            failures.append(f"{path.relative_to(ROOT)}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}: {source[node.start_byte:node.end_byte][:100]!r}")
        stack.extend(reversed(node.children))
if failures:
    raise SystemExit("\n".join(failures))
print(f"PASS: parsed {len(files)} Swift files without syntax errors. Apple SDK typechecking still requires Xcode.")
