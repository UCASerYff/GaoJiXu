/* Adventure camera, lighting and models. All art is loaded from the bundled Mac assets. */
(() => {
  "use strict";

  const scenes = new Map();
  const sources = new Map();
  const motion = matchMedia("(prefers-reduced-motion: reduce)");
  const macTexture = name => "/assets/mac/" + name + ".png";
  const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
  const cross = (a,b) => [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
  const dot = (a,b) => a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
  const normalize = a => {
    const length = Math.hypot(...a) || 1;
    return a.map(value => value / length);
  };
  const subtract = (a,b) => a.map((value,index) => value - b[index]);
  const add = (a,b) => a.map((value,index) => value + b[index]);
  const plane = [
    -.5,-.5,0, 0,0, 0,0,1,  .5,-.5,0, 1,0, 0,0,1,  .5,.5,0, 1,1, 0,0,1,
    -.5,-.5,0, 0,0, 0,0,1,  .5,.5,0, 1,1, 0,0,1,  -.5,.5,0, 0,1, 0,0,1
  ];
  const flat = [[1,0,0],[0,1,0],[0,0,1]];
  const ground = [[1,0,0],[0,0,-1],[0,1,0]];
  const sourceLight = normalize([.42,.72,.56]);

  // Matrix-free camera basis is also used by the keyboard-accessible DOM hit areas.
  function cameraFor(scene, width, height) {
    const camp = scene.mode === "camp";
    const center = [0, camp ? 1.6 : 2, 0];
    const aspect = width / Math.max(height,1);
    const halfHeight = Math.max(camp ? 5.8 : 4.8, (camp ? 6.28 : 5) / aspect);
    const distance = scene.orbit ? scene.distance : 20;
    const yaw = scene.orbit ? scene.yaw : 0;
    const pitch = scene.orbit ? scene.pitch : 0;
    const eye = add(center,[Math.sin(yaw)*Math.cos(pitch)*distance,Math.sin(pitch)*distance,Math.cos(yaw)*Math.cos(pitch)*distance]);
    const back = normalize(subtract(eye,center));
    const right = normalize(cross([0,1,0],back));
    const up = cross(back,right);
    const zoom = scene.orbit ? halfHeight / 20 : halfHeight;
    return {eye,right,up,back,zoom,aspect,perspective:scene.orbit};
  }

  function project(point, camera, width, height) {
    const relative = subtract(point,camera.eye);
    const depth = -dot(relative,camera.back);
    const scale = (camera.perspective ? Math.max(.1,depth) : 1) * camera.zoom;
    return [width * (.5 + dot(relative,camera.right) / (scale*camera.aspect) * .5),
      height * (.5 - dot(relative,camera.up) / scale * .5)];
  }

  const vertex = [
    "attribute vec3 aPosition; attribute vec2 aUV; attribute vec3 aNormal;",
    "uniform vec3 uOrigin, uScale, uEye, uRight, uUp, uBack;",
    "uniform mat3 uBasis; uniform float uZoom, uAspect, uPerspective;",
    "varying vec2 vUV; varying vec3 vNormal;",
    "void main() {",
    "  vec3 relative = uOrigin + uBasis * (aPosition*uScale) - uEye;",
    "  float x = dot(relative,uRight) / (uZoom*uAspect);",
    "  float y = dot(relative,uUp) / uZoom;",
    "  float depth = -dot(relative,uBack);",
    "  if (uPerspective > .5) gl_Position = vec4(x, y, (100.1/99.9)*depth - 20.0/99.9, depth);",
    "  else gl_Position = vec4(x, y, (2.0/99.9)*depth - 100.1/99.9, 1.0);",
    "  vUV = aUV; vNormal = normalize(uBasis*(aNormal/uScale));",
    "}"
  ].join("\n");
  const fragment = [
    "precision mediump float; varying vec2 vUV; varying vec3 vNormal;",
    "uniform sampler2D uImage; uniform vec4 uUV, uColor;",
    "uniform vec3 uSun; uniform float uMode, uLighting;",
    "void main() {",
    "  vec4 hue = uColor;",
    "  if (uMode > .5 && uMode < 1.5) hue *= texture2D(uImage, uUV.xy + vUV*uUV.zw);",
    "  if (uMode > 1.5) hue.a *= 1.0 - smoothstep(.2,.5,length(vUV-vec2(.5)));",
    "  if (hue.a < .045) discard;",
    "  float direct = .66 + .38*max(dot(normalize(vNormal),uSun),0.0);",
    "  gl_FragColor = vec4(hue.rgb * mix(1.0,direct,uLighting), hue.a);",
    "}"
  ].join("\n");

  function shader(gl, kind, source) {
    const result = gl.createShader(kind);
    gl.shaderSource(result,source);
    gl.compileShader(result);
    if (!gl.getShaderParameter(result,gl.COMPILE_STATUS)) {
      const problem = gl.getShaderInfoLog(result);
      gl.deleteShader(result);
      throw new Error(problem);
    }
    return result;
  }

  function vertexMesh(triangles) {
    const values = [];
    for (const points of triangles) {
      const [a,b,c] = points;
      const normal = normalize(cross(subtract(b,a),subtract(c,a)));
      for (const point of points) values.push(...point, 0,0, ...normal);
    }
    return values;
  }

  function cube() {
    const triangles = [];
    const positions = [[-.5,-.5,-.5],[.5,-.5,-.5],[.5,.5,-.5],[-.5,.5,-.5],[-.5,-.5,.5],[.5,-.5,.5],[.5,.5,.5],[-.5,.5,.5]];
    const faces = [[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[0,1,5,4],[3,7,6,2]];
    for (const [a,b,c,d] of faces) triangles.push([positions[a],positions[b],positions[c]],[positions[a],positions[c],positions[d]]);
    return vertexMesh(triangles);
  }

  function cylinder(topRadius) {
    const triangles = [];
    for (let index = 0; index < 16; index++) {
      const a = index*Math.PI/8, b = (index+1)*Math.PI/8;
      const point = (angle, height, radius) => [Math.cos(angle)*radius,height,Math.sin(angle)*radius];
      const bottomA = point(a,-.5,.5), bottomB = point(b,-.5,.5);
      const topA = point(a,.5,topRadius), topB = point(b,.5,topRadius);
      triangles.push([bottomA,topA,bottomB],[bottomA,bottomB,[0,-.5,0]]);
      if (topRadius > 0) triangles.push([topA,topB,bottomB],[topB,topA,[0,.5,0]]);
    }
    return vertexMesh(triangles);
  }

  function sphere() {
    const values = [];
    const point = (ring, side) => {
      const latitude = ring * Math.PI / 10, longitude = side * Math.PI / 8;
      const normal = [Math.sin(latitude)*Math.cos(longitude),Math.cos(latitude),Math.sin(latitude)*Math.sin(longitude)];
      return [...normal.map(value => value*.5), 0,0, ...normal];
    };
    for (let row=0; row<10; row++) for (let col=0; col<16; col++) {
      const a=point(row,col), b=point(row+1,col), c=point(row+1,col+1), d=point(row,col+1);
      values.push(...a,...b,...c,...a,...c,...d);
    }
    return values;
  }

  function torus() {
    const values = [];
    const point = (around,tube) => {
      const a = around*Math.PI/16, b = tube*Math.PI/4;
      return [(0.95+.04*Math.cos(b))*Math.cos(a),.04*Math.sin(b),(0.95+.04*Math.cos(b))*Math.sin(a), 0,0,
        Math.cos(b)*Math.cos(a), Math.sin(b), Math.cos(b)*Math.sin(a)];
    };
    for (let row=0;row<32;row++) for (let col=0;col<8;col++) {
      const a=point(row,col), b=point(row+1,col), c=point(row+1,col+1), d=point(row,col+1);
      values.push(...a,...b,...c,...a,...c,...d);
    }
    return values;
  }

  const shapeData = {plane, cube:cube(), cylinder:cylinder(.5), cone:cylinder(0), sphere:sphere(), ring:torus()};
  const insets = source => {
    const [x,y,w,h] = source || [0,0,1,1];
    return [x,1-y-h,w,h];
  };
  const tile = (index,count,rows) => [index%count/count, Math.floor(index/count)/rows, 1/count, 1/rows];

  function sourceImage(name) {
    if (!sources.has(name)) {
      const image = new Image();
      const loading = new Promise((resolve,reject) => {
        image.onload = () => resolve(image);
        image.onerror = reject;
      });
      image.src = macTexture(name);
      sources.set(name,loading);
    }
    return sources.get(name);
  }

  function renderer(canvas, restored) {
    const gl = restored || canvas.getContext("webgl",{alpha:true,antialias:true,premultipliedAlpha:false});
    if (!gl || gl.isContextLost()) return null;
    const vertexShader = shader(gl,gl.VERTEX_SHADER,vertex);
    const fragmentShader = shader(gl,gl.FRAGMENT_SHADER,fragment);
    const program = gl.createProgram();
    gl.attachShader(program,vertexShader);
    gl.attachShader(program,fragmentShader);
    gl.linkProgram(program);
    gl.deleteShader(vertexShader);
    gl.deleteShader(fragmentShader);
    if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    gl.useProgram(program);
    const uniform = {};
    const attribute = {};
    for (const field of ["Origin","Scale","Eye","Right","Up","Back","Basis","Zoom","Aspect","Perspective","Image","UV","Color","Sun","Mode","Lighting"]) {
      uniform[field] = gl.getUniformLocation(program,"u"+field);
    }
    for (const field of ["Position","UV","Normal"]) {
      attribute[field] = gl.getAttribLocation(program,"a"+field);
      gl.enableVertexAttribArray(attribute[field]);
    }
    const meshes = Object.fromEntries(Object.entries(shapeData).map(([name,values]) => {
      const buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
      gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(values),gl.STATIC_DRAW);
      return [name,{buffer,vertices:values.length/8}];
    }));
    const textures = new Map();
    gl.uniform3fv(uniform.Sun,sourceLight);
    gl.uniform1i(uniform.Image,0);
    gl.clearColor(0,0,0,0);
    gl.enable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);
    let bound = null;

    function texture(name,image) {
      const value = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D,value);
      gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
      textures.set(name,value);
    }

    function begin(camera) {
      gl.viewport(0,0,canvas.width,canvas.height);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.uniform3fv(uniform.Eye,camera.eye);
      gl.uniform3fv(uniform.Right,camera.right);
      gl.uniform3fv(uniform.Up,camera.up);
      gl.uniform3fv(uniform.Back,camera.back);
      gl.uniform1f(uniform.Aspect,camera.aspect);
      gl.uniform1f(uniform.Perspective,Number(camera.perspective));
      gl.uniform1f(uniform.Zoom,camera.zoom);
    }

    function paint(shape,origin,scale,color,{basis=flat,art,uv,shadow=false,lighting=1}={}) {
      const mesh = meshes[shape];
      if (bound !== mesh) {
        bound = mesh;
        gl.bindBuffer(gl.ARRAY_BUFFER,mesh.buffer);
        gl.vertexAttribPointer(attribute.Position,3,gl.FLOAT,false,32,0);
        gl.vertexAttribPointer(attribute.UV,2,gl.FLOAT,false,32,12);
        gl.vertexAttribPointer(attribute.Normal,3,gl.FLOAT,false,32,20);
      }
      if (art) {
        const picture = textures.get(art);
        if (!picture) return;
        gl.bindTexture(gl.TEXTURE_2D,picture);
        gl.uniform4fv(uniform.UV,insets(uv));
      }
      gl.uniform3fv(uniform.Origin,origin);
      gl.uniform3fv(uniform.Scale,scale);
      gl.uniformMatrix3fv(uniform.Basis,false,basis.flat());
      gl.uniform4fv(uniform.Color,color);
      gl.uniform1f(uniform.Mode,shadow?2:art?1:0);
      gl.uniform1f(uniform.Lighting,lighting);
      gl.depthMask(!shadow);
      gl.drawArrays(gl.TRIANGLES,0,mesh.vertices);
      if (shadow) gl.depthMask(true);
    }

    function dispose() {
      for (const {buffer} of Object.values(meshes)) gl.deleteBuffer(buffer);
      for (const image of textures.values()) gl.deleteTexture(image);
      gl.deleteProgram(program);
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    }
    return {gl,textures,texture,begin,paint,dispose};
  }

  const paint = {
    leather:[.26,.20,.15], boot:[.17,.22,.26], chest:[.30,.46,.58], steel:[.61,.72,.72],
    gold:[.91,.67,.31], hair:[.24,.22,.20], skin:[.81,.63,.47], cloth:[.18,.40,.43],
    walnut:[.31,.22,.18], shale:[.29,.37,.40], wood:[.51,.36,.24], terracotta:[.38,.22,.18],
    parchment:[.78,.67,.48], light:[.98,.79,.36], sage:[.38,.58,.30], violet:[.53,.39,.58],
  };
  const heroModel = [
    ["cube",[-.27,.44,0],[.26,.88,.35],paint.boot], ["cube",[.27,.44,0],[.26,.88,.35],paint.boot],
    ["cube",[-.27,.14,.16],[.30,.22,.49],paint.leather], ["cube",[.27,.14,.16],[.30,.22,.49],paint.leather],
    ["cube",[0,1.27,0],[.88,1.05,.57],paint.chest], ["cube",[0,.93,.32],[.84,.16,.09],paint.leather],
    ["cube",[0,1.30,-.40],[.94,1.7,.1],paint.cloth], ["cube",[0,1.60,.31],[.74,.47,.14],paint.steel],
    ["sphere",[0,2.10,0],[.69,.72,.68],paint.skin], ["sphere",[0,2.36,-.08],[.78,.55,.75],paint.hair],
    ["sphere",[-.55,1.74,0],[.43,.35,.5],paint.steel], ["sphere",[.55,1.74,0],[.43,.35,.5],paint.steel],
    ["cube",[-.58,1.35,0],[.27,.63,.30],paint.chest], ["cube",[.61,1.38,.13],[.27,.63,.30],paint.chest],
    ["cube",[-.62,1.06,.06],[.21,.23,.24],paint.skin], ["cube",[.68,1.06,.2],[.21,.23,.24],paint.skin],
    ["cube",[.79,1.22,.22],[.38,.11,.16],paint.gold], ["cube",[.78,1.94,.22],[.14,1.48,.12],paint.steel],
    ["cone",[.78,2.76,.22],[.14,.19,.14],paint.steel], ["cube",[-.63,1.24,.23],[.48,.65,.18],paint.cloth],
    ["cube",[-.63,1.23,.34],[.09,.42,.05],paint.gold],
  ];
  const monsterTints = [[.55,.81,.23],[.67,.42,.59],[.41,.62,.59],[.82,.76,.6],[.73,.50,.24],
    [.50,.36,.45],[.58,.74,.39],[.57,.48,.68],[.62,.48,.35],[.42,.58,.32]];
  const campTints = [[.57,.40,.28],[.43,.49,.65],[.69,.56,.37],[.64,.49,.65]];
  const petTints = [[.9,.69,.43],[.84,.71,.52],[.83,.84,.83],[.62,.55,.40],[.42,.58,.34],[.71,.54,.38],
    [.85,.43,.24],[.53,.38,.28],[.83,.85,.83],[.46,.64,.77],[.74,.46,.28],[.68,.46,.28]];
  const rotation = angle => [[Math.cos(angle),Math.sin(angle),0],[-Math.sin(angle),Math.cos(angle),0],[0,0,1]];
  const campItems = [
    ["equipment", -4.5, 3, 2.7],["technique",4.5,2,3],["pets",-4.5,-2,2.7],["lottery",4.5,-2.3,2.7]
  ];

  function itemsFor(mode,data) {
    if (mode === "camp") {
      return campItems.map(([id,x,y,height],index) => {
        const right = index%2, bottom = index>=2;
        const uv = [right ? .572 : 0, bottom ? .508 : 0, right ? .428 : .572, bottom ? .492 : .508];
        return {id,index,kind:"camp",position:[x,y,0],width:height*uv[2]/uv[3],height,offset:height/2,
          labelOffset:-.22,art:"AdventureBuildingsV353",uv};
      });
    }
    const monster = clamp(Number(data.monsterSprite)||0,0,9);
    const team = data.equippedPets.map(id => data.petCatalog.find(pet => pet.id === id)).filter(Boolean);
    return [
      {id:"hero",kind:"hero",position:[-3.4,0,0],width:2.5,height:3.75,offset:1.7,labelOffset:3.6,art:"AdventureHeroV353"},
      {id:"monster",kind:"monster",index:monster,position:[3.3,0,0],width:2.7,height:3.10,offset:1.7,labelOffset:3.6,
        art:"MonsterSpriteSheetV16",uv:tile(monster,5,2)},
      ...team.map((pet,index) => {
        const stage = pet.stars>=4?2:pet.stars>=2?1:0;
        const cell = Math.floor(pet.sprite/2)*6+(pet.sprite%2)*3+stage;
        return {id:pet.id,kind:"pet",index:pet.sprite,position:[-3.4+(index-(team.length-1)/2)*1.6,-1.55,2.8],
          width:1.23,height:1.23,offset:.69,art:"PetSpriteSheetV16",uv:tile(cell,6,6)};
      })
    ];
  }

  function monsterModel(item) {
    const color = monsterTints[item.index], dark = color.map(value=>value*.62);
    const faces = (x,y,z,width) => [-width,width].flatMap(eye=>[
      ["sphere",[x+eye,y,z],[.18,.20,.13],[.07,.10,.07]],
      ["sphere",[x+eye-.025,y+.034,z+.064],[.053,.055,.028],[.96,.96,.80]]
    ]);
    switch (item.index) {
    case 0: // Coin Slime
      return [
        ["sphere",[0,.49,0],[1.9,.97,1.60],color], ["sphere",[0,.82,0],[1.49,1.20,1.35],color],
        ["sphere",[0,.61,.62],[1.21,.51,.52],[.58,.84,.27]], ...faces(0,.92,.81,.34),
        ["sphere",[0,.68,.88],[.22,.13,.13],[.13,.19,.08]],
        ...[[-.69,.13,.42],[.70,.13,.46],[-.58,.95,.20],[.13,1.50,0]].flatMap(([x,y,z])=>[
          ["cylinder",[x,y,z],[.38,.09,.38],paint.gold],
          ["cylinder",[x,y+.045,z],[.29,.06,.29],[.98,.83,.48]],
        ])
      ];
    case 1: // Impulse Moth
      return [
        ["sphere",[0,1.21,0],[.54,1.39,.51],dark], ["sphere",[0,1.94,.10],[.68,.62,.6],color],
        ...[-1,1].flatMap(side=>[
          ["sphere",[side*.65,1.54,-.04],[1.18,1.51,.28],color,rotation(side*.25)],
          ["sphere",[side*.59,.95,.02],[.76,.87,.22],dark],
          ["cone",[side*.23,2.29,0],[.13,.55,.12],dark,rotation(side*-.28)]
        ]), ...faces(0,1.98,.42,.16)
      ];
    case 2: // Budget Stone Golem
      return [
        ["cube",[0,1.1,0],[1.32,1.17,.91],color], ["cube",[0,2.02,0],[.90,.71,.82],dark],
        ["cylinder",[0,1.38,.43],[.51,.16,.51],paint.gold,[[1,0,0],[0,0,1],[0,-1,0]]],
        ...[-1,1].flatMap(side=>[
          ["cube",[side*.39,.315,.14],[.46,.63,.57],dark],
          ["cube",[side*.94,1.07,.15],[.43,.80,.56],color],
        ]), ...faces(0,2.05,.45,.19)
      ];
    case 3: // Receipt Paper Ball
      return [
        ...Array.from({length:9},(_,index)=>["cube",[Math.cos(index*2.3)*.29,.87+Math.sin(index*2.3)*.38,Math.sin(index)*.31],
          [1.29,.75,.97],index%2?color:paint.parchment,rotation(index*.50)]),
        ...faces(0,1.22,.70,.34)
      ];
    case 4: // Snack Crate
      return [
        ["cube",[0,.68,0],[1.61,1.36,1.2],color], ["cube",[0,.79,.64],[1.35,.73,.10],paint.parchment],
        ["cube",[0,1.47,.21],[1.6,.12,.63],dark,rotation(.28)], ["cube",[0,1.61,-.3],[1.6,.12,.63],dark,rotation(-.28)],
        ...faces(0,1,.71,.32), ["cube",[0,.38,.62],[.47,.16,.09],dark]
      ];
    case 5: // Subscription Spider
      return [
        ["sphere",[0,.82,-.30],[1.27,1.18,1.53],color], ["sphere",[0,.59,.43],[.96,.90,1.03],dark],
        ...Array.from({length:8},(_,i)=>{
          const side=i<4?-1:1, z=(i%4-1.5)*.41;
          return ["cube",[side*.86,.50,z],[.19,1.34,.18],dark,rotation(side*-.9)];
        }), ...faces(0,.71,.88,.23)
      ];
    case 6: // Price Tag Caterpillar
      return [
        ...Array.from({length:5},(_,i)=>["sphere",[(i-2)*.41,.55+Math.sin(i*.68)*.24,0],
          [.62,.89,.80],i%2?dark:color]),
        ["sphere",[.93,1,.12],[.79,.78,.78],color], ...faces(.91,1.08,.51,.17)
      ];
    case 7: // Anxiety Eye
      return [
        ["sphere",[0,1.25,0],[1.54,1.44,1.48],color], ["sphere",[0,1.33,.64],[1.03,.96,.31],[.93,.86,.74]],
        ["sphere",[0,1.35,.81],[.55,.69,.15],dark], ["sphere",[.055,1.42,.89],[.19,.25,.05],[.07,.03,.12]],
        ["sphere",[-.070,1.54,.93],[.15,.15,.05],[1,.96,.81]],
        ...Array.from({length:6},(_,i)=>["sphere",[Math.cos(i*1.2)*.58,.54+Math.sin(i*1.2)*.22,Math.sin(i)*.31],
          [.48,.41,.55],i%2?dark:color])
      ];
    case 8: // Shopping Bag Heap
      return [
        ...[[-.56,.63,.06],[.47,.83,-.29],[.28,.31,.46]].flatMap(([x,y,z],i)=>[
          ["cube",[x,y,z],[.93,1.13-i*.13,.76],i%2?dark:color,rotation(.18-i*.20)],
          ["ring",[x,y+.48,z],[.40,.40,.40],paint.gold,[[1,0,0],[0,0,1],[0,-1,0]]],
        ]), ...faces(.32,.63,.86,.17)
      ];
    default: // Procrastination Snail
      return [
        ["sphere",[.12,.37,.02],[2.06,.66,1.02],color],
        ["sphere",[-.38,.87,-.06],[1.43,1.43,1.48],[.58,.39,.26]],
        ["sphere",[-.38,.90,.64],[.87,.85,.21],[.73,.55,.30]],
        ["sphere",[-.39,.91,.77],[.48,.53,.17],[.40,.29,.21]],
        ["sphere",[.77,.70,.11],[.62,.70,.66],color], ...faces(.78,.84,.50,.14)
      ];
    }
  }

  function campModel(item) {
    const color = campTints[item.index];
    const entry = [
      ["cube",[0,-.02,0],[2.82,.19,2.06],paint.shale],
      ["cube",[0,.72,0],[2.16,1.38,1.62],color],
      ["cube",[0,.44,.83],[.49,.88,.06],paint.walnut],
      ...[-.62,.62].flatMap(x=>[
        ["cube",[x,.93,.84],[.44,.45,.045],paint.walnut],
        ["cube",[x,.93,.87],[.33,.34,.040],paint.light],
        ["cube",[x,.93,.89],[.038,.35,.03],paint.wood]
      ])
    ];
    switch (item.index) {
    case 0:
      entry.push(["cone",[0,1.87,0],[3.15,1.18,2.53],paint.terracotta],
        ["cube",[-.79,1.99,-.28],[.49,1.04,.52],paint.shale],
        ["cube",[-.79,2.5,-.28],[.61,.17,.65],paint.terracotta],
        ["cube",[.79,.20,1.08],[.52,.39,.39],paint.wood]);
      break;
    case 1:
      entry.push(["cone",[0,1.75,0],[3.15,.68,2.48],paint.shale],
        ["cylinder",[0,2.20,0],[1.04,1.22,1.04],color],["cone",[0,3.08,0],[1.39,.96,1.39],paint.shale],
        ["sphere",[0,3.58,0],[.13,.13,.13],paint.gold]);
      break;
    case 2:
      entry.push(["cone",[0,1.77,0],[3.23,1.07,2.64],paint.sage],
        ["cube",[0,1.03,1.12],[2.62,.2,.55],paint.wood],
        ["cylinder",[-.94,.38,1.36],[.08,.84,.08],paint.walnut],
        ["cylinder",[.94,.38,1.36],[.08,.84,.08],paint.walnut]);
      break;
    default:
      entry.push(["cone",[0,1.78,0],[3.12,.99,2.55],paint.violet],
        ["cylinder",[0,2.13,0],[.89,.27,.88],paint.shale],
        ["sphere",[0,2.46,0],[.62,.62,.62],[.73,.58,.93]],
        ["sphere",[0,2.49,0],[.25,.25,.25],[.91,.79,1]]);
    }
    return entry;
  }

  function modelFor(item) {
    if (item.kind === "hero") return heroModel;
    if (item.kind === "monster") return monsterModel(item);
    if (item.kind === "camp") return campModel(item);
    const color = petTints[item.index];
    return [["sphere",[0,.41,0],[.91,.79,.9],color],["sphere",[.25,.74,0],[.56,.53,.56],color],
      ["sphere",[.32,.78,.26],[.078,.086,.06],paint.hair],["sphere",[.13,.78,.24],[.078,.086,.06],paint.hair],
      ["cone",[.07,.99,.13],[.22,.23,.22],color],["cone",[.44,.98,.05],[.22,.23,.22],color]];
  }

  function easing(phase) {
    return clamp(phase,0,1);
  }

  function itemPosition(item,time,attack) {
    const position = item.position.slice();
    if (motion.matches) return position;
    const elapsed = time - attack;
    if (item.kind === "hero" && elapsed >= 0 && elapsed < 400) {
      position[0] += 1.2*(elapsed<160 ? easing(elapsed/160) : easing((400-elapsed)/240));
    } else if (item.kind === "monster" && elapsed >= 160 && elapsed < 520) {
      position[0] += .35*(elapsed<240 ? easing((elapsed-160)/80) : easing((520-elapsed)/280));
    } else if (item.kind === "pet") {
      const phase = ((time+item.index*193)%4400)/2200;
      const movement = phase>1?2-phase:phase;
      position[0] += .12*movement;
      position[2] += .08*movement;
    }
    return position;
  }

  function positionOverlay(button,item,position,camera,width,height) {
    if (!button) return;
    const center = add(position,[0,item.offset,0]);
    const half = camera.perspective ? Math.max(item.width,item.kind==="camp"?3:1.65)*.5 : item.width*.5;
    const depth = camera.perspective ? item.kind==="camp"?1.4:.76 : 0;
    const right = camera.perspective ? [1,0,0] : camera.right;
    const edges = [-half,half].flatMap(x => [-item.height/2,item.height/2].flatMap(y =>
      [-depth,depth].map(z => project(add(center,[right[0]*x,y,right[2]*x+z]),camera,width,height))));
    const xs = edges.map(point=>point[0]);
    const ys = edges.map(point=>point[1]);
    const [left,top] = [Math.min(...xs),Math.min(...ys)];
    const [,labelY] = project(add(position,[0,item.labelOffset ?? .7,0]),camera,width,height);
    button.style.setProperty("--actor-x",left+"px");
    button.style.setProperty("--actor-y",top+"px");
    button.style.setProperty("--actor-w",Math.max(14,Math.max(...xs)-left)+"px");
    button.style.setProperty("--actor-h",Math.max(16,Math.max(...ys)-top)+"px");
    button.style.setProperty("--actor-label-y",(labelY-top)+"px");
  }

  const white = [1,1,1,1];
  function draw(scene,time) {
    const {element,canvas,graphic} = scene;
    const width = element.clientWidth, height = element.clientHeight;
    if (!width || !height || !graphic || graphic.gl.isContextLost() || scene.unavailable) return;
    if (scene.items.some(item => !graphic.textures.has(item.art))) return;
    const factor = Math.min(2,window.devicePixelRatio || 1);
    const pixelsWide = Math.round(width*factor), pixelsHigh = Math.round(height*factor);
    if (canvas.width !== pixelsWide || canvas.height !== pixelsHigh) {
      canvas.width = pixelsWide;
      canvas.height = pixelsHigh;
    }
    const camera = cameraFor(scene,width,height);
    graphic.begin(camera);
    const positions = scene.items.map(item => itemPosition(item,time,scene.attackAt));
    if (scene.orbit) {
      scene.items.forEach((item,index) => {
        const position = positions[index];
        if (scene.mode==="battle") {
          const base = item.kind==="pet" ? 1.33 : 2.26;
          graphic.paint("cylinder",add(position,[0,-.085,0]),[base,.17,base*.75],[.37,.32,.23,1]);
          graphic.paint("cylinder",add(position,[0,-.008,0]),[base*.96,.036,base*.73],[.54,.46,.32,1]);
        }
        graphic.paint("plane",add(position,[.33,.026,-.25]),[item.width*1.36,item.width*.85,1],
          [.10,.08,.055,.53],{basis:ground,shadow:true,lighting:0});
        item.model ||= modelFor(item);
        for (const [shape,offset,scale,color,basis] of item.model) {
          graphic.paint(shape,add(position,offset),scale,[...color,1],{basis});
        }
      });
    } else {
      const billboard = [camera.right,[0,1,0],normalize(cross(camera.right,[0,1,0]))];
      scene.items.forEach((item,index) => {
        const start = positions[index];
        graphic.paint("plane",add(start,[0,item.offset,0]),[item.width,item.height,1],white,
          {basis:item.kind==="monster"||item.kind==="pet"?flat:billboard,art:item.art,uv:item.uv,lighting:0});
      });
    }
    if (scene.selected) {
      const index = scene.items.findIndex(item => item.id === scene.selected);
      if (index >= 0) graphic.paint("ring",add(positions[index],[0,.08,0]),[1,1,1],[1,.72,.25,1]);
    }
    for (const [index,item] of scene.items.entries()) positionOverlay(scene.overlays[index],item,positions[index],camera,width,height);
    element.dataset.renderer = "webgl";
  }

  function loop(scene,time) {
    scene.frame = 0;
    if (!scene.visible || !scene.element.isConnected || scene.unavailable) return;
    if (!scene.lastFrame || time-scene.lastFrame>=30 || scene.dirty) {
      draw(scene,time);
      scene.lastFrame = time;
      scene.dirty = false;
    }
    const active = !motion.matches && (time-scene.attackAt<550 || scene.items.some(item=>item.kind==="pet"));
    if (active) scene.frame = requestAnimationFrame(next=>loop(scene,next));
  }

  function repaint(scene) {
    scene.dirty = true;
    if (!scene.frame && scene.visible) scene.frame = requestAnimationFrame(time=>loop(scene,time));
  }

  function cacheArtwork(scene) {
    const graphic = scene.graphic;
    if (!graphic) return;
    for (const name of new Set(scene.items.map(item=>item.art))) {
      if (graphic.textures.has(name) || scene.loading.has(name)) continue;
      scene.loading.add(name);
      sourceImage(name).then(image=>{
        if (scene.graphic !== graphic || graphic.gl.isContextLost() || !scene.element.isConnected) return;
        graphic.texture(name,image);
        scene.loading.delete(name);
        repaint(scene);
      }).catch(()=>{
        scene.unavailable = true;
        scene.element.removeAttribute("data-renderer");
      });
    }
  }

  function initScene(element,mode,interactive,str) {
    const canvas = document.createElement("canvas");
    canvas.className = "adv-scene-canvas";
    canvas.setAttribute("aria-hidden","true");
    let graphic;
    try { graphic = renderer(canvas); }
    catch (error) { console.warn("Adventure WebGL:",error); }
    if (!graphic) { scenes.set(element,null); return null; }
    element.prepend(canvas);
    const scene = {element,mode,interactive,canvas,graphic,items:[],overlays:[],loading:new Set(),
      visible:false,frame:0,attackAt:-Infinity,orbit:false,yaw:.32,pitch:.34,distance:20,selected:null};
    scenes.set(element,scene);
    if (interactive) initControls(scene,str);
    scene.visibility = new IntersectionObserver(([entry])=>{
      scene.visible = entry.isIntersecting;
      if (scene.visible) repaint(scene);
      else if (scene.frame) {
        cancelAnimationFrame(scene.frame);
        scene.frame = 0;
      }
    });
    scene.visibility.observe(element);
    scene.resize = new ResizeObserver(()=>repaint(scene));
    scene.resize.observe(element);
    canvas.addEventListener("webglcontextlost",event=>{
      event.preventDefault();
      scene.unavailable = true;
      scene.loading.clear();
      element.removeAttribute("data-renderer");
      element.classList.remove("adv-orbit");
    });
    canvas.addEventListener("webglcontextrestored",()=>{
      try { scene.graphic = renderer(canvas,graphic.gl); }
      catch (error) { console.warn("Adventure WebGL restore:",error); }
      scene.unavailable = !scene.graphic;
      element.classList.toggle("adv-orbit", scene.orbit);
      cacheArtwork(scene);
      repaint(scene);
    });
    return scene;
  }

  function initControls(scene,str) {
    const {element} = scene;
    const controls = document.createElement("div");
    controls.className = "adv-scene-controls";
    const hint = document.createElement("span");
    hint.textContent = str("拖动旋转 · 滚轮缩放 · 方向键调整","Drag to orbit · Scroll to zoom · Arrow keys to adjust");
    hint.hidden = true;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "adv-scene-view";
    button.textContent = str("立体视角","3D view");
    button.setAttribute("aria-pressed","false");
    controls.append(hint,button);
    element.append(controls);
    button.addEventListener("click",event=>{
      event.stopPropagation();
      scene.orbit = !scene.orbit;
      element.classList.toggle("adv-orbit",scene.orbit);
      hint.hidden = !scene.orbit;
      button.setAttribute("aria-pressed",String(scene.orbit));
      button.textContent = scene.orbit ? str("正面视角","Front view") : str("立体视角","3D view");
      repaint(scene);
    });
    button.addEventListener("keydown",event=>{
      if (!scene.orbit || !["ArrowUp","ArrowDown","ArrowLeft","ArrowRight","-","+"].includes(event.key)) return;
      event.preventDefault();
      if (event.key==="ArrowLeft" || event.key==="ArrowRight") scene.yaw = clamp(scene.yaw+(event.key==="ArrowLeft"?-.12:.12),-1.12,1.12);
      if (event.key==="ArrowUp" || event.key==="ArrowDown") scene.pitch = clamp(scene.pitch+(event.key==="ArrowDown"?-.10:.10),.08,.85);
      if (event.key==="-" || event.key==="+") scene.distance = clamp(scene.distance+(event.key==="-"?1.2:-1.2),10,27);
      repaint(scene);
    });
    let grip = null;
    element.addEventListener("pointerdown",event=>{
      if (!scene.orbit || event.button!==0 || event.target.closest("button")) return;
      grip = [event.clientX,event.clientY];
      element.setPointerCapture(event.pointerId);
    });
    element.addEventListener("pointermove",event=>{
      if (!grip) return;
      scene.yaw = clamp(scene.yaw+(event.clientX-grip[0])*.009,-1.12,1.12);
      scene.pitch = clamp(scene.pitch+(event.clientY-grip[1])*.007,.08,.85);
      grip = [event.clientX,event.clientY];
      repaint(scene);
    });
    element.addEventListener("lostpointercapture",()=>{grip=null;});
    element.addEventListener("wheel",event=>{
      if (!scene.orbit || event.ctrlKey) return;
      event.preventDefault();
      scene.distance = clamp(scene.distance+Math.sign(event.deltaY),10,27);
      repaint(scene);
    },{passive:false});
  }

  function synchronize(element,mode,data,interactive,str,selected=false) {
    const scene = scenes.has(element) ? scenes.get(element) : initScene(element,mode,interactive,str);
    if (!scene) return;
    const key = mode==="camp" ? "camp" : [data.monsterSprite,...data.equippedPets.map(id=>id+":"+data.petCatalog.find(pet=>pet.id===id)?.stars)].join(",");
    if (scene.key!==key) {
      scene.items = itemsFor(mode,data);
      scene.key = key;
      cacheArtwork(scene);
    }
    scene.overlays = [...element.querySelectorAll(":scope > .adv-actor")];
    scene.selected = selected ? "monster" : null;
    if (interactive && scene.token!==undefined && scene.token < data.attackCount && mode==="battle") {
      scene.attackAt = performance.now();
    }
    scene.token = data.attackCount;
    repaint(scene);
  }

  new MutationObserver(()=>{
    for (const [element,scene] of scenes) if (!element.isConnected) {
      scenes.delete(element);
      if (!scene) continue;
      scene.visibility.disconnect();
      scene.resize.disconnect();
      if (scene.frame) cancelAnimationFrame(scene.frame);
      scene.graphic?.dispose();
    }
  }).observe(document.documentElement,{childList:true,subtree:true});

  window.GaoAdventureScene = {update:synchronize};
})();
