from pathlib import Path
import os, subprocess, tempfile
s=Path('MSG/AppSwitcherPreview.swift').read_text()
search=s[s.index('enum MSGSwitcherSearch {'):s.index('private enum MSGSwitcherSlot:')]
method=s[s.index('    private func apply(_ input:'):s.index('    /// Rebuilds `items`')].replace('private func apply','func apply')
harness='import AppKit\n'+search+'''
enum MSGSwitcherInput { case begin(Bool), key(Int,String,Bool,Bool), commit, cancel }
class Harness {
var suppressInitialHover=false, canHover=false, searchActive=false, iconLayout=false
var initialMouseLocation: NSPoint? = nil
var query="", selected=0, items=[0,1], closed=0, quit=0, hidden=0
func commit() {}
func dismiss() {}
func layoutPanel(animated: Bool) {}
func filter() {}
func moveApp(_ d:Int, wrapping:Bool) {}
func moveWindow(_ d:Int) {}
func moveRow(_ d:Int) {}
func closeSelected() { closed += 1 }
func quitSelected() { quit += 1 }
func hideSelected() { hidden += 1 }
'''+method+'''
}
let h=Harness()
h.apply(.key(0,"a",false,false))
assert(!h.searchActive && h.query.isEmpty)
h.apply(.key(13,"w",false,false))
assert(h.closed==1)
h.apply(.key(3,"f",false,false))
assert(h.searchActive && h.query.isEmpty)
for (code,text) in [(13,"w"),(12,"q"),(4,"h"),(3,"f"),(0,"ก")] { h.apply(.key(code,text,false,false)) }
assert(h.query=="wqhfก" && h.closed==1 && h.quit==0 && h.hidden==0)
for _ in 0..<5 { h.apply(.key(51,"",false,false)) }
assert(h.query.isEmpty && h.searchActive)
h.apply(.key(48,"",false,false))
assert(h.selected==1)
print("PASS: F entry, ignored typing before search, safe W/Q/H in search, Unicode, delete-to-empty, navigation")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';p.write_text(harness)
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
 exe=str(Path(tmp)/'test')
 subprocess.run(['xcrun','swiftc',str(p),'-sdk',sdk,'-o',exe],env=env,check=True)
 subprocess.run([exe],check=True)
