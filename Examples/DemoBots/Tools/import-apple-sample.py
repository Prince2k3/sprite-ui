#!/usr/bin/env python3
"""Import licensed art/levels from Apple's extracted DemoBots 2.3 sample.
Usage: python3 import-apple-sample.py /path/to/extracted-apple-sample
Only resource files are imported; gameplay is implemented with SpriteUI.
"""
import json, pathlib, plistlib, shutil, sys
source = pathlib.Path(sys.argv[1])
root = pathlib.Path(__file__).resolve().parents[1]
assets = source / 'DemoBots/Assets'
output = root / 'App/Assets.xcassets'
output.mkdir(parents=True, exist_ok=True)
shutil.copytree(assets/'Images.xcassets/AppIcon.appiconset', output/'AppIcon.appiconset', dirs_exist_ok=True)
(output/'Contents.json').write_text(json.dumps({'info': {'author':'xcode','version':1}}))
frames = {}
selected = {'PlayerBotIdle':2,'PlayerBotWalk':4,'PlayerBotHit':2,'PlayerBotInactive':2,
 'GroundBotGoodWalk':4,'GroundBotBadWalk':4,'GroundBotAttack':3,'GroundBotZapped':2,
 'FlyingBotGoodWalk':4,'FlyingBotBadWalk':4,'FlyingBotGoodAttack':3,'FlyingBotBadAttack':3,'FlyingBotZapped':2}
count=0
for catalog in assets.rglob('*.xcassets'):
 for imageset in catalog.rglob('*.imageset'):
  stem=imageset.name.removesuffix('.imageset')
  parts=stem.rsplit('_',2)
  animated=len(parts)==3 and parts[0] in selected
  if catalog.name in ('PlayerBot.xcassets','GroundBot.xcassets','FlyingBot.xcassets') and not animated: continue
  if animated and int(parts[2])>=selected[parts[0]]: continue
  if not animated and catalog.name not in ('Scenery.xcassets','Images.xcassets') and not catalog.name.startswith('Level'): continue
  entries=json.loads((imageset/'Contents.json').read_text()).get('images',[])
  files=[e for e in entries if e.get('filename') and (imageset/e['filename']).exists()]
  if not files: continue
  # Keep one universal raster per frame, avoiding the original six device variants.
  preferred=next((e for e in files if e.get('idiom')=='ipad' and e.get('scale')=='1x'),files[0])
  dest=output/(stem+'.imageset');dest.mkdir(exist_ok=True)
  shutil.copy2(imageset/preferred['filename'],dest/'image.png')
  (dest/'Contents.json').write_text(json.dumps({'images':[{'filename':'image.png','idiom':'universal'}],'info':{'author':'xcode','version':1}},indent=2))
  count+=1
  if animated: frames.setdefault(parts[0],{}).setdefault(parts[1],[]).append(stem)
resources=root/'Game/Resources'
for i in range(1,4):
 p=assets/f'Scenes/Levels/Level{i}'
 for extension in ('sks','plist'): shutil.copy2(p/f'Level{i}.{extension}',resources/f'Level{i}.{extension}')
for directions in frames.values():
 for names in directions.values(): names.sort()
(resources/'animation-frames.json').write_text(json.dumps(frames,sort_keys=True))
shutil.copy2(source/'LICENSE.txt',root/'APPLE-LICENSE.txt')
# A level must never ship with SpriteKit's missing-texture placeholders.
missing = set()
for scene in resources.glob('Level*.sks'):
 archive = plistlib.loads(scene.read_bytes()); objects = archive['$objects']
 for obj in objects:
  if isinstance(obj,dict) and '_imgName' in obj:
   name = objects[obj['_imgName'].data]
   if isinstance(name,str) and not (output/(name+'.imageset')/'image.png').exists(): missing.add(name)
if missing: raise SystemExit(f'Missing level textures: {sorted(missing)}')
print(f'Imported {count} image sets, three original levels, configuration, animation manifest, and Apple license.')
