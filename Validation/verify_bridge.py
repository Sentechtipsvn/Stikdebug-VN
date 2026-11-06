"""Interpret only the ten generated bridge actions; not an iPhone execution test."""
from pathlib import Path
import plistlib
import urllib.parse

workflow = plistlib.loads(Path("Shortcuts/StikDebug-VN.unsigned.shortcut").read_bytes())
actions = workflow["WFWorkflowActions"]
assert len(actions) == 10
assert workflow["WFWorkflowInputContentItemClasses"] == ["WFURLContentItem", "WFStringContentItem"]
assert "ActionExtension" in workflow["WFWorkflowTypes"]

def run(shared):
    outputs, opened, branch = {}, [], True
    def value(node):
        if isinstance(node, str): return node
        if node.get("WFSerializationType") == "WFTextTokenAttachment": return value(node["Value"])
        if node.get("WFSerializationType") == "WFTextTokenString":
            data = node["Value"]; text = data["string"]
            for at, token in sorted(data["attachmentsByRange"].items(), reverse=True):
                offset = int(at.split(",")[0][1:]); text = text[:offset] + value(token) + text[offset+1:]
            return text
        if node.get("Type") == "ExtensionInput": return shared or ""
        if node.get("Type") == "ActionOutput": return outputs[node["OutputUUID"]]
        if node.get("Type") == "Variable": return value(node["Variable"])
        raise AssertionError(node)
    for action in actions:
        ident = action["WFWorkflowActionIdentifier"].removeprefix("is.workflow.actions.")
        p = action["WFWorkflowActionParameters"]
        if ident == "conditional":
            if p["WFControlFlowMode"] == 0:
                assert p["WFCondition"] == 100; branch = bool(value(p["WFInput"]))
            elif p["WFControlFlowMode"] == 1: branch = not branch
            else: branch = True
            continue
        if not branch: continue
        if ident == "comment": continue
        if ident == "gettext": result = value(p["WFTextActionText"])
        elif ident == "urlencode":
            assert p["WFEncodeMode"] == "Encode"; result = urllib.parse.quote(value(p["WFInput"]), safe="")
        elif ident == "url": result = value(p["WFURLActionURL"])
        elif ident == "openurl": opened.append(value(p["WFInput"])); continue
        else: raise AssertionError(ident)
        outputs[p["UUID"]] = result
    assert len(opened) == 1
    return opened[0]

assert run(None) == "stikdebugvn://create-route"
assert run("") == "stikdebugvn://create-route"
for payload in ["10.87139,106.73716", "https://maps.apple.com/?ll=10.87139,106.73716&q=Nhà & Kho + #1", "Quán cà phê\nhttps://maps.app.goo.gl/aBc?x=1&y=2", "https://www.google.com/maps/search/?api=1&query=10.87139%2C106.73716"]:
    url = urllib.parse.urlsplit(run(payload))
    assert (url.scheme, url.netloc) == ("stikdebugvn", "receive-location")
    assert urllib.parse.parse_qs(url.query) == {"input": [payload]}
print("PASS: 6 bridge routing/encoding cases; 10 native actions validated")
