import AppKit
import SceneKit
@main struct ExplorerWorldRegression {
 static func main()throws {
  _=NSApplication.shared
  for mode in ["station","expedition"] {
   for stage in (mode == "station" ? [1,4] : [0,1,2,3,4]) {
    var items=[GQWorldItem(id:"__world",title:"",kind:"__world",level:stage,x:0,z:0,movable:false)]
    if mode=="station" {
     let kinds=["compute","archive","studio","habitat"],sites:[(Double,Double)]=[(-3.7,2.8),(-3.7,-3.1),(3.7,2.8),(3.7,-3.1)]
     for i in 0..<4 { items.append(GQWorldItem(id:kinds[i],title:kinds[i],kind:kinds[i],level:stage,x:sites[i].0,z:sites[i].1,movable:false)) }
    } else { items.append(GQWorldItem(id:"probe",title:"",kind:"probe",level:2,x:-5,z:2,movable:false)) }
    let scene=GQWorldBuilder.scene(mode:mode,items:items,selectedID:nil)
    let camera=scene.rootNode.childNode(withName:"camera",recursively:false)!
    if mode=="station" { let a=32.0*Double.pi/180;camera.position=SCNVector3(sin(a)*17,12,cos(a)*17);camera.camera?.orthographicScale=9.4 }
    else {camera.position=SCNVector3(2,6,19);camera.camera?.orthographicScale=7.7;scene.rootNode.childNode(withName:"item:probe",recursively:true)?.position.y=1.1}
    camera.look(at:SCNVector3(0,0,0))
    let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
    renderer.update(atTime:0);renderer.update(atTime:1)
    let im=renderer.snapshot(atTime:1,with:CGSize(width:1500,height:900),antialiasingMode:.multisampling4X)
    let data=NSBitmapImageRep(data:im.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    try data.write(to:URL(fileURLWithPath:"\(CommandLine.arguments.dropFirst().first ?? "/tmp/gq361")-\(mode)-\(stage).png"))
    assert(scene.rootNode.childNode(withName:mode=="station" ? "probe-hull" : "survey-planet",recursively:true) != nil)
    print("Rendered \(mode) \(stage)")
   }
  }
 }
}
