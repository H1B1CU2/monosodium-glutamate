from pathlib import Path
import subprocess,os,tempfile,re
s=Path('MSG/AppSwitcherPreview.swift').read_text()
s_source=s
a=s.index('    var gridHeight: CGFloat {');b=s.index('    var selectedItem:',a)
constants='\n'.join(re.findall(r'    static let (?:hoverSlack|sectionGap|dividerHeight|labelGap|sectionHeaderHeight|rowGap): CGFloat = [0-9]+',s))
h='import AppKit\nstruct Section { var rows:[CGFloat]; var title:String?=nil; var showDivider=false }\nstruct Layout {\n'+constants+'''
var loading=false,items=[1],cellHeight:CGFloat=100
var sections:[Section]
func rowHeight(_ row:CGFloat)->CGFloat { row }
'''+s[a:b]+'''
}
assert(Layout(sections:[Section(rows:[100])]).gridHeight==140)
assert(Layout(sections:[Section(rows:[100,100,100,900])]).gridHeight==384)
assert(Layout(sections:[Section(rows:[100,100,100]),Section(rows:[900],title:"Other",showDivider:true)]).gridHeight==384)
assert(Layout(sections:[Section(rows:[100],title:"Current"),Section(rows:[120,140,900],title:"Other",showDivider:true)]).gridHeight==519)
assert(Layout(sections:[Section(rows:[100,100],title:"Other")]).gridHeight==288)
print("PASS: one/two/three rows, varying row heights, crossing divider, no trailing fourth-row heading")
'''
fit_start=s_source.index('    private func fitGridRows(in frame:')
fit_end=s_source.index('    private func panelTarget(in frame:',fit_start)
fit=s_source[fit_start:fit_end].replace('private func fitGridRows','func fitGridRows')
h += '''
class Signal { func send() {} }
class Settings { var dockPreviewThumbHeight: CGFloat = 240 }
class Fit {
var iconLayout=false, loading=false, searchActive=false
var items=[1], thumbHeight:CGFloat=240
var settings=Settings(), objectWillChange=Signal()
var gridHeight:CGFloat { thumbHeight * 3 + 260 }
'''+fit+'''
}
let fitting=Fit()
fitting.fitGridRows(in:CGRect(x:0,y:0,width:1200,height:800))
assert(fitting.gridHeight+20<=760)
assert(fitting.thumbHeight<240)
fitting.searchActive=true
fitting.fitGridRows(in:CGRect(x:0,y:0,width:1200,height:800))
assert(fitting.gridHeight+20<=680)
fitting.searchActive=false
fitting.fitGridRows(in:CGRect(x:0,y:0,width:1800,height:1400))
assert(fitting.thumbHeight==240)
print("PASS: fitting small screens, reserving detached search space, restoring requested size on larger displays")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';p.write_text(h);exe=str(Path(tmp)/'test')
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
 subprocess.run(['xcrun','swiftc',str(p),'-sdk',sdk,'-o',exe],env=env,check=True)
 subprocess.run([exe],check=True)
