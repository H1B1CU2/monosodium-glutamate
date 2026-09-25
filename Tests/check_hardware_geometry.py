#!/usr/bin/env python3
"""Exercise production AppKit layout without opening a window or running MSG."""
from pathlib import Path
import re,subprocess,os,tempfile
root=Path(__file__).resolve().parents[1]
build=(root/'build.sh').read_text().split('xcrun -sdk macosx swiftc',1)[1].split('-o "$MACOS/$APP_NAME"',1)[0]
sources=re.findall(r'^\s+([\w/]+\.swift)\s+\\',build,re.M)
files=[str(root/'MSG'/p) for p in sources if p!='main.swift']
frameworks=['AppKit','CoreAudio','Carbon','CoreVideo','SwiftUI','ServiceManagement','IOKit','ImageIO','MediaRemote','SkyLight']
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
with tempfile.TemporaryDirectory(prefix='msg-hardware-geometry-') as tmp:
    executable=str(Path(tmp)/'geometry-tests')
    cmd=['xcrun','--sdk','macosx','swiftc',*files,str(root/'Tests/HardwarePopoverGeometryTests.swift'),'-sdk',sdk,'-target','arm64-apple-macos14.0','-F/System/Library/PrivateFrameworks','-o',executable]
    for framework in frameworks:cmd+=['-framework',framework]
    subprocess.run(cmd,env=env,check=True)
    subprocess.run([executable],check=True)
