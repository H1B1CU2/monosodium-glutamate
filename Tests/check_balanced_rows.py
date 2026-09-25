from pathlib import Path
import os, subprocess, tempfile
s=Path('MSG/AppSwitcherPreview.swift').read_text()
a=s.index('    static func balancedRowRanges(');b=s.index('    /// Moves the selection one row',a)
h='import AppKit\nenum Layout {\n'+s[a:b]+'''
}
func pack(_ widths: [CGFloat], _ ids: [pid_t]? = nil, budget: CGFloat = 430) -> [Range<Int>] {
 Layout.balancedRowRanges(widths: widths, appIDs: ids ?? Array(repeating: 1,count: widths.count), budget: budget, intraGap: 10, interGap: 20)
}
assert(pack([]).isEmpty)
assert(pack(Array(repeating: 100,count: 5)).map(\\.count) == [3,2])
assert(pack(Array(repeating: 100,count: 6)).map(\\.count) == [3,3])
assert(pack(Array(repeating: 100,count: 7)).map(\\.count) == [4,3])
assert(pack(Array(repeating: 100,count: 9)).map(\\.count) == [3,3,3])
assert(pack([500,100,100]).map(\\.count) == [1,2])
for seed in 1...100 {
 let n=1+seed%8
 let widths=(0..<n).map { CGFloat(70+(seed*31+$0*67)%210) }
 let ids=(0..<n).map { pid_t(($0+seed)%3) }
 let rows=pack(widths,ids)
 assert(rows.flatMap { Array($0) } == Array(0..<n))
 func fits(_ range: Range<Int>) -> Bool {
  let width=range.reduce(CGFloat(0)) { $0+widths[$1] } + range.dropFirst().reduce(CGFloat(0)) { $0+(ids[$1]==ids[$1-1] ? 10:20) }
  return range.count==1 || width<=430
 }
 assert(rows.allSatisfy(fits))
 let actual=(rows.count,rows.reduce(0) { $0+$1.count*$1.count })
 for mask in 0..<(1 << max(0,n-1)) {
  var candidate:[Range<Int>]=[]; var start=0
  for end in 1...n {
   if end==n || (mask & (1 << (end-1))) != 0 { candidate.append(start..<end);start=end }
  }
  if candidate.allSatisfy(fits) {
   let score=(candidate.count,candidate.reduce(0) { $0+$1.count*$1.count })
   assert(actual.0<score.0 || (actual.0==score.0 && actual.1<=score.1))
  }
 }
}
print("PASS: balanced 5/6/7/9-card layouts, empty/oversized inputs, width/order constraints and exhaustive optimality across 100 varied cases")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';p.write_text(h)
 env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
 exe=str(Path(tmp)/'test')
 subprocess.run(['xcrun','swiftc',str(p),'-sdk',sdk,'-o',exe],env=env,check=True)
 subprocess.run([exe],check=True)
