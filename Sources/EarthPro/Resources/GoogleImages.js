// A projected triangle mesh supports rotation and image warping on the regular Google map.
window.earthImages = items => {
  (window.earthGroundImages || []).forEach(x=>x.setMap(null));
  class Ground extends google.maps.OverlayView {
    constructor(item){super();this.item=item;this.image=new Image();this.image.onload=()=>this.draw();this.image.src=item.image;this.setMap(map);}
    onAdd(){this.canvas=document.createElement('canvas');this.canvas.style.position='absolute';this.canvas.style.pointerEvents='none';this.getPanes().overlayLayer.append(this.canvas);}
    onRemove(){this.canvas?.remove();this.image.onload=null;}
    draw(){
      if(!this.canvas||!this.image.complete||!this.image.naturalWidth)return;
      const projection=this.getProjection();if(!projection)return;
      const p=this.item.points.map(p=>projection.fromLatLngToDivPixel(new google.maps.LatLng(p.lat,p.lng)));
      const left=Math.min(...p.map(p=>p.x)),top=Math.min(...p.map(p=>p.y)),w=Math.max(...p.map(p=>p.x))-left,h=Math.max(...p.map(p=>p.y))-top;
      if(!Number.isFinite(w)||!Number.isFinite(h)||w<1||h<1)return;
      const scale=Math.min(1,4096/w,4096/h),canvas=this.canvas;
      canvas.width=Math.max(1,Math.ceil(w*scale));canvas.height=Math.max(1,Math.ceil(h*scale));
      Object.assign(canvas.style,{left:left+'px',top:top+'px',width:w+'px',height:h+'px',opacity:this.item.opacity});
      const ctx=canvas.getContext('2d'),iw=this.image.naturalWidth,ih=this.image.naturalHeight;
      const point=(x,y)=>({x:(p[y*13+x].x-left)*scale,y:(p[y*13+x].y-top)*scale});
      const triangle=(uv)=>{
        const d=uv.map(([x,y])=>point(x,y)),s=uv.map(([x,y])=>({x:x/12*iw,y:(1-y/12)*ih}));
        const dx1=s[1].x-s[0].x,dy1=s[1].y-s[0].y,dx2=s[2].x-s[0].x,dy2=s[2].y-s[0].y,det=dx1*dy2-dx2*dy1;
        const a=((d[1].x-d[0].x)*dy2-(d[2].x-d[0].x)*dy1)/det,c=(dx1*(d[2].x-d[0].x)-dx2*(d[1].x-d[0].x))/det;
        const b=((d[1].y-d[0].y)*dy2-(d[2].y-d[0].y)*dy1)/det,e=(dx1*(d[2].y-d[0].y)-dx2*(d[1].y-d[0].y))/det;
        ctx.save();ctx.beginPath();ctx.moveTo(d[0].x,d[0].y);ctx.lineTo(d[1].x,d[1].y);ctx.lineTo(d[2].x,d[2].y);ctx.closePath();ctx.clip();
        ctx.setTransform(a,b,c,e,d[0].x-a*s[0].x-c*s[0].y,d[0].y-b*s[0].x-e*s[0].y);ctx.drawImage(this.image,0,0);ctx.restore();
      };
      for(let y=0;y<12;y++)for(let x=0;x<12;x++){triangle([[x,y],[x+1,y],[x+1,y+1]]);triangle([[x,y],[x+1,y+1],[x,y+1]]);}
    }
  }
  window.earthGroundImages=items.map(item=>new Ground(item));
};
