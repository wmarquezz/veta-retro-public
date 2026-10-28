#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex veta_vertex(uint id [[vertex_id]]) {
    float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    Vertex out;out.position=float4(p[id],0,1);out.uv=float2((p[id].x+1)/2,(1-p[id].y)/2);return out;
}
/*
   Hyllian's xBR-lv2 Shader

   Copyright (C) 2011-2022 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a
   copy of this software and associated documentation files (the
   "Software"), to deal in the Software without restriction, including
   without limitation the rights to use, copy, modify, merge, publish,
   distribute, sublicense, and/or sell copies of the Software, and to permit
   persons to whom the Software is furnished to do so, subject to the
   following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
   THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.

   Incorporates some of the ideas from SABR shader. Thanks to Joshua Street.
*/
// MSL port: spatial taps clamp within each DS/3DS image.
namespace xbr {
#define CORNER_C
float4 clamp01(float4 x){return clamp(x,0.0,1.0);}
float4 tap(texture2d<float> frame,float2 uv,float2 range){
constexpr sampler nn(coord::normalized,address::clamp_to_edge,filter::nearest);
uv.y=clamp(uv.y,range.x,range.y);return frame.sample(nn,uv);
}
constant float4 Ao = float4( 1.0, -1.0, -1.0, 1.0 );
constant float4 Bo = float4( 1.0,  1.0, -1.0,-1.0 );
constant float4 Co = float4( 1.5,  0.5, -0.5, 0.5 );
constant float4 Ax = float4( 1.0, -1.0, -1.0, 1.0 );
constant float4 Bx = float4( 0.5,  2.0, -0.5,-2.0 );
constant float4 Cx = float4( 1.0,  1.0, -0.5, 0.0 );
constant float4 Ay = float4( 1.0, -1.0, -1.0, 1.0 );
constant float4 By = float4( 2.0,  0.5, -2.0,-0.5 );
constant float4 Cy = float4( 2.0,  0.0, -1.0, 0.5 );
constant float4 Ci = float4(0.25, 0.25, 0.25, 0.25);

constant float3 v2f = float3( 65536, 256, 1); // vec to float encode
constant float3 Y = float3(0.2627, 0.6780, 0.0593);

// Return if A components are less than or equal B ones.
float4 LTE(float4 A, float4 B)
{
    return step(A, B);
}

// Return if A components are less than B ones.
float4 LT(float4 A, float4 B)
{
    return float4(A < B);
}

// Return logically inverted vector components. BEWARE: Only works with 0.0 or 1.0 components.
float4 NOT(float4 A)
{
    return (float4(1.0) - A);
}

// Compare two vectors and return their components are different.
float4 diff(float4 A, float4 B)
{
    return float4(A != B);
}

float dist(float3 A, float3 B)
{
    return dot(abs(A-B), Y);
}

// Calculate color distance between two vectors of four pixels
float4 dist4(float4x3 A, float4x3 B)
{
    return float4(dist(A[0],B[0]), dist(A[1],B[1]), dist(A[2],B[2]), dist(A[3],B[3]));
}

// Tests if color components are under a threshold. In this case they are considered 'equal'.
float4 eq(float4x3 A, float4x3 B)
{
    return (step(dist4(A, B), float4(0.32)));
}

// Determine if two vector components are NOT equal based on a threshold.
float4 neq(float4x3 A, float4x3 B)
{
    return (float4(1.0, 1.0, 1.0, 1.0) - eq(A, B));
}

// Calculate weighted distance among pixels in some directions.
float4 weighted_distance(float4x3 a, float4x3 b, float4x3 c, float4x3 d, float4x3 e, float4x3 f, float4x3 g, float4x3 h)
{
    return (dist4(a,b) + dist4(a,c) + dist4(d,e) + dist4(d,f) + 4.0*dist4(g,h));
}



float4 scale(texture2d<float> frame,float2 texCoord,bool split) {
float2 size=float2(frame.get_width(),frame.get_height());
float halfTexel=0.5/size.y;float low=split && texCoord.y>=0.5 ? 0.5:0.0;
float2 range=float2(low+halfTexel,(split ? low+0.5:1.0)-halfTexel);
float dx=1.0/size.x,dy=1.0/size.y;
float aa_factor=max(0.001,2.0*length(dfdx(texCoord*size)));
   float4 t1 = texCoord.xxxy + float4( -dx, 0, dx,-2.0*dy); // A1 B1 C1
   float4 t2 = texCoord.xxxy + float4( -dx, 0, dx,    -dy); //  A  B  C
   float4 t3 = texCoord.xxxy + float4( -dx, 0, dx,      0); //  D  E  F
   float4 t4 = texCoord.xxxy + float4( -dx, 0, dx,     dy); //  G  H  I
   float4 t5 = texCoord.xxxy + float4( -dx, 0, dx, 2.0*dy); // G5 H5 I5
   float4 t6 = texCoord.xyyy + float4(-2.0*dx,-dy, 0,  dy); // A0 D0 G0
   float4 t7 = texCoord.xyyy + float4( 2.0*dx,-dy, 0,  dy); // C4 F4 I4
    float4 edri, edr, edr_l, edr_u, px; // px = pixel, edr = edge detection rule
    float4 irlv0, irlv1, irlv2l, irlv2u;
    float4 fx, fx_l, fx_u; // inequations of straight lines.
    float3 res1, res2;
    float4 fx45i, fx45, fx30, fx60;

    float2 fp  = fract(texCoord*size);

    float3 A1 = tap(frame,t1.xw,range).xyz;
    float3 B1 = tap(frame,t1.yw,range).xyz;
    float3 C1 = tap(frame,t1.zw,range).xyz;
    float3 A  = tap(frame,t2.xw,range).xyz;
    float3 B  = tap(frame,t2.yw,range).xyz;
    float3 C  = tap(frame,t2.zw,range).xyz;
    float3 D  = tap(frame,t3.xw,range).xyz;
    float3 E  = tap(frame,t3.yw,range).xyz;
    float3 F  = tap(frame,t3.zw,range).xyz;
    float3 G  = tap(frame,t4.xw,range).xyz;
    float3 H  = tap(frame,t4.yw,range).xyz;
    float3 I  = tap(frame,t4.zw,range).xyz;
    float3 G5 = tap(frame,t5.xw,range).xyz;
    float3 H5 = tap(frame,t5.yw,range).xyz;
    float3 I5 = tap(frame,t5.zw,range).xyz;
    float3 A0 = tap(frame,t6.xy,range).xyz;
    float3 D0 = tap(frame,t6.xz,range).xyz;
    float3 G0 = tap(frame,t6.xw,range).xyz;
    float3 C4 = tap(frame,t7.xy,range).xyz;
    float3 F4 = tap(frame,t7.xz,range).xyz;
    float3 I4 = tap(frame,t7.xw,range).xyz;

    float4x3 b  = float4x3(B, D, H, F);
    float4x3 c  = float4x3(C, A, G, I);
    float4x3 d  = float4x3(D, H, F, B);
    float4x3 e  = float4x3(E, E, E, E);
    float4x3 f  = float4x3(F, B, D, H);
    float4x3 g  = float4x3(G, I, C, A);
    float4x3 h  = float4x3(H, F, B, D);
    float4x3 i  = float4x3(I, C, A, G);

    float4x3 i4 = float4x3(I4, C1, A0, G5);
    float4x3 i5 = float4x3(I5, C4, A1, G0);
    float4x3 h5 = float4x3(H5, F4, B1, D0);
    float4x3 f4 = float4x3(F4, B1, D0, H5);

    float4 b_   = float4(dot(v2f,b[0]),dot(v2f,b[1]),dot(v2f,b[2]),dot(v2f,b[3]));
    float4 c_   = float4(dot(v2f,c[0]),dot(v2f,c[1]),dot(v2f,c[2]),dot(v2f,c[3]));
    float4 d_   = b_.yzwx;
    float4 e_   = float4(dot(v2f,e[0]),dot(v2f,e[1]),dot(v2f,e[2]),dot(v2f,e[3]));
    float4 f_   = b_.wxyz;
    float4 g_   = c_.zwxy;
    float4 h_   = b_.zwxy;
    float4 i_   = c_.wxyz;

    float4 i4_  = float4(dot(v2f,i4[0]),dot(v2f,i4[1]),dot(v2f,i4[2]),dot(v2f,i4[3]));
    float4 i5_  = float4(dot(v2f,i5[0]),dot(v2f,i5[1]),dot(v2f,i5[2]),dot(v2f,i5[3]));
    float4 h5_  = float4(dot(v2f,h5[0]),dot(v2f,h5[1]),dot(v2f,h5[2]),dot(v2f,h5[3]));
    float4 f4_  = h5_.yzwx;

    // These inequations define the line below which interpolation occurs.
    fx    = ( Ao*fp.y + Bo*fp.x );
    fx_l  = ( Ax*fp.y + Bx*fp.x );
    fx_u  = ( Ay*fp.y + By*fp.x );

    irlv0 = diff(e_,f_) * diff(e_,h_);
    irlv1 = irlv0;

#ifdef CORNER_B
    irlv1      = clamp01(irlv0 * ( neq(f,b) * neq(h,d) + eq(e,i) * neq(f,i4) * neq(h,i5) + eq(e,g) + eq(e,c) ) );
#endif
#ifdef CORNER_C
    irlv1     = clamp01(irlv0  * ( neq(f,b) * neq(f,c) + neq(h,d) * neq(h,g) + eq(e,i) * (neq(f,f4) * neq(f,i4) + neq(h,h5) * neq(h,i5)) + eq(e,g) + eq(e,c)) );
#endif

    irlv2l = diff(e_,g_) * diff( d_, g_);
    irlv2u = diff(e_,c_) * diff( b_, c_);

    if (1.0 == 1.0) {
        float4 delta  = float4(aa_factor);
        float4 deltaL = float4(0.5, 1.0, 0.5, 1.0) * aa_factor;
        float4 deltaU = deltaL.yxwz;

        fx45i = clamp01( 0.5 + (fx   - Co - Ci) / delta  );
        fx45  = clamp01( 0.5 + (fx   - Co     ) / delta  );
        fx30  = clamp01( 0.5 + (fx_l - Cx     ) / deltaL );
        fx60  = clamp01( 0.5 + (fx_u - Cy     ) / deltaU );
    }
    else {
        fx45i = LT( Co + Ci, fx   );
        fx45  = LT(      Co, fx   );
        fx30  = LT(      Cx, fx_l );
        fx60  = LT(      Cy, fx_u );
    }

    float4 wd1 = weighted_distance( e, c,  g, i, h5, f4, h, f);
    float4 wd2 = weighted_distance( h, d, i5, f, i4,  b, e, i);

    float4 d_fg = dist4(f, g);
    float4 d_hc = dist4(h, c);

    edri      = LTE(wd1, wd2) * irlv0;
    edr       = LT( wd1, wd2) * irlv1 * NOT(edri.yzwx * edri.wxyz);
    edr_l     = LTE( 2.3 * d_fg, d_hc ) * irlv2l * edr * (NOT(edri.yzwx) * eq(e, c));
    edr_u     = LTE( 2.3 * d_hc, d_fg ) * irlv2u * edr * (NOT(edri.wxyz) * eq(e, g));

    fx45i = edri   * fx45i;
    fx45  = edr    * fx45;
    fx30  = edr_l  * fx30;
    fx60  = edr_u  * fx60;

    px = LTE(dist4(e,f), dist4(e,h));

    float4 maximos = max(max(fx30, fx60), max(fx45, fx45i));

    res1 = mix(E, mix(H, F, px.x), maximos.x);
    res2 = mix(E, mix(B, D, px.z), maximos.z);

    float3 res1a = mix(res1, res2, step(dist(E, res1), dist(E, res2)));

    res1 = mix(E, mix(F, B, px.y), maximos.y);
    res2 = mix(E, mix(D, H, px.w), maximos.w);

    float3 res1b = mix(res1, res2, step(dist(E, res1), dist(E, res2)));

    float3 res = mix(res1a, res1b, step(dist(E, res1a), dist(E, res1b)));


return float4(res,1.0);
}

#undef CORNER_C
}
fragment float4 veta_fragment(Vertex in [[stage_in]], texture2d<float> frame [[texture(0)]], constant uint2 &settings [[buffer(0)]]) {
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=in.uv;
    switch(settings.y & 0xff) {
        case 1: uv=float2(fract(in.uv.x*2),in.uv.y*0.5+(in.uv.x<0.5 ? 0.0:0.5));break;
        case 2: uv.y=0.5+uv.y*0.5;break;
        case 3: uv.y*=0.5;break;
        case 4: uv.y=uv.y<0.5 ? uv.y+0.5:uv.y-0.5;break;
    }
    if(settings.y & 0x200) {
        constexpr float split=5.0/9.0;
        uv=in.uv.x<split ? float2(in.uv.x/split,in.uv.y*0.5)
            : float2(0.1+(in.uv.x-split)/(1.0-split)*0.8,0.5+in.uv.y*0.5);
    }
    // Each DS half is a separate image: linear taps must not cross its seam.
    if((settings.x==1 || settings.x==4) && (settings.y & 0x100)) {
        float lower=uv.y>=0.5 ? 0.5:0.0;
        float halfTexel=0.5/float(frame.get_height());
        uv.y=clamp(uv.y,lower+halfTexel,lower+0.5-halfTexel);
    }
    // Smooth transitions between texels while keeping their centers crisp.
    // One bilinear sample; no sharpening halos, temporal history or core changes.
    if(settings.x==4) {
        float2 size=float2(frame.get_width(),frame.get_height());
        float2 pixel=uv*size-0.5;
        uv=(floor(pixel)+smoothstep(float2(0),float2(1),fract(pixel))+0.5)/size;
    }
    if(settings.x==5)return xbr::scale(frame,uv,(settings.y & 0x100)!=0);
    float4 color=(settings.x==1 || settings.x==4) ? frame.sample(linear,uv):frame.sample(nearest,uv);
    float2 cell=fract(uv*float2(frame.get_width(),frame.get_height()));
    if(settings.x==2) color.rgb*=cell.y>0.65 ? 0.78:1.0;
    if(settings.x==3) color.rgb*=cell.x>0.85 || cell.y>0.85 ? 0.72:1.0;
    return float4(color.rgb,1);
}
