"""Build a native Apple Shortcuts share bridge without third-party app actions."""
from pathlib import Path
import plistlib
import uuid

ROOT = Path(__file__).resolve().parent
NS = uuid.UUID("c782ead0-6d4c-4711-868b-af09d68c02e2")
def uid(name): return str(uuid.uuid5(NS, name)).upper()
def attachment(value): return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}
def output(name): return attachment({"Type": "ActionOutput", "OutputUUID": uid(name), "OutputName": {"text": "Text", "encode": "URL Encoded Text", "receive": "URL", "compose": "URL"}[name]})
def token(value, prefix=""):
    return {"Value": {"string": prefix + "\ufffc", "attachmentsByRange": {f"{{{len(prefix)}, 1}}": value}}, "WFSerializationType": "WFTextTokenString"}
def action(name, identifier, **params):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions." + identifier,
            "WFWorkflowActionParameters": {"UUID": uid(name), **params}}

def build():
    group = uid("if-group")
    actions = [
        action("comment", "comment", WFCommentActionText="StikDebug VN · 3.2.2\n© Sentechtipsvn\nChia sẻ link Google/Apple Maps → chọn cách dùng trong StikDebug VN. Mở không có đầu vào → soạn tuyến. Điểm dừng và thời gian nghỉ nhập trong ứng dụng."),
        action("if", "conditional", GroupingIdentifier=group, WFControlFlowMode=0, WFCondition=100,
               WFInput={"Type": "Variable", "Variable": attachment({"Type": "ExtensionInput"})}),
        action("text", "gettext", WFTextActionText=token({"Type": "ExtensionInput"})),
        action("encode", "urlencode", WFEncodeMode="Encode", WFInput=output("text")),
        action("receive", "url", WFURLActionURL=token(output("encode")["Value"], "stikdebugvn://receive-location?input=")),
        action("open-receive", "openurl", WFInput=output("receive")),
        action("otherwise", "conditional", GroupingIdentifier=group, WFControlFlowMode=1),
        action("compose", "url", WFURLActionURL="stikdebugvn://create-route"),
        action("open-compose", "openurl", WFInput=output("compose")),
        action("end-if", "conditional", GroupingIdentifier=group, WFControlFlowMode=2),
    ]
    workflow = {
        "WFWorkflowName": "StikDebug VN", "WFWorkflowActions": actions,
        "WFQuickActionSurfaces": [], "WFWorkflowClientVersion": "5037.109",
        "WFWorkflowHasOutputFallback": False, "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59769, "WFWorkflowIconStartColor": 0x34C759FF},
        "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 3010, "WFWorkflowMinimumClientVersionString": "3010",
        "WFWorkflowOutputContentItemClasses": [], "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch", "ActionExtension"],
    }
    target = ROOT / "StikDebug-VN.unsigned.shortcut"
    target.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_XML, sort_keys=False))
    return target
if __name__ == "__main__": print(build())
