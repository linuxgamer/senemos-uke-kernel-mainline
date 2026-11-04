// SPDX-License-Identifier: GPL-2.0-only
/* Actual extracted production functions; synthetic state and providers only. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define BIT(n) (1U << (n))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define GFP_KERNEL 0
#define DRM_MODE_ENCODER_DSI 6
#define DRM_MODE_COLORIMETRY_DEFAULT 0
#define DRM_MODE_COLORIMETRY_BT2020_RGB 9
#define HDMI_EOTF_TRADITIONAL_GAMMA_SDR 0
#define HDMI_EOTF_SMPTE_ST2084 2
enum dpu_dspp { DSPP_0=1,DSPP_1,DSPP_2,DSPP_3,DSPP_MAX };
enum { DPU_DSPP_PCC=1,DPU_DSPP_GC,DPU_DSPP_IGC,DPU_DSPP_GAMUT,DPU_DSPP_PA };
enum { INTF_1=2,INTF_2,INTF_MODE_VIDEO=1,DPU_ENC_DISABLED=0 };
struct mutex { bool held; };
static void mutex_lock(struct mutex *m) { assert(!m->held);m->held=true; }
static void mutex_unlock(struct mutex *m) { assert(m->held);m->held=false; }
struct drm_device;
struct drm_encoder { struct drm_device *dev; unsigned int encoder_type; };
struct drm_device { void *dev_private; struct drm_encoder *encoders[2]; };
struct drm_crtc_state;
struct drm_crtc { struct drm_device *dev; struct drm_crtc_state *state; };
struct drm_property_blob { unsigned int length; void *data; };
struct drm_color_lut { uint16_t red,green,blue,reserved; };
struct hdr_output_metadata { unsigned int metadata_type; struct { u8 eotf,metadata_type; } hdmi_metadata_type1; };
struct drm_connector { struct drm_encoder *encoder; };
struct drm_connector_state { struct drm_crtc *crtc; unsigned int colorspace; struct drm_property_blob *hdr_output_metadata; };
struct drm_atomic_commit { unsigned int nconn; struct drm_connector *connector; struct drm_connector_state *old,*new; };
struct drm_crtc_state {
 struct drm_crtc *crtc; struct drm_atomic_commit *state; unsigned int encoder_mask;
 bool enable,active,self_refresh_active,mode_changed; struct drm_property_blob *gamma_lut;
};
struct dpu_hw_ctl { struct { void (*update_pending_flush_dspp)(struct dpu_hw_ctl *,enum dpu_dspp,u32); } ops; u32 pending_dspp_flush_mask[4],pending_flush_mask; };
struct dpu_hw_dspp { unsigned int idx; };
struct dpu_crtc_mixer { struct dpu_hw_dspp *hw_dspp; struct dpu_hw_ctl *lm_ctl; };
struct dpu_crtc_state {
 struct drm_crtc_state base; bool o82_native_color,o82_bt2020,o82_pq;
 unsigned int num_mixers,num_ctls; struct dpu_crtc_mixer mixers[2]; struct dpu_hw_ctl *hw_ctls[2];
};
struct msm_kms { unsigned int tag; };
struct dpu_o82_color;
struct dpu_o82_regdma { bool closing; };
struct dpu_kms { struct msm_kms base; struct dpu_o82_color *o82_color; struct dpu_o82_regdma *o82_regdma; };
struct msm_drm_private { struct msm_kms *kms; };
struct dpu_o82_profiles { const void *fw; unsigned int selected; };
struct dpu_o82_color_input { const u8 *igc,*gamut,*gc; unsigned int primaries,dither_strength; bool dither_enabled,pa_managed; };
struct dpu_hw_gc_lut { u32 c0[512],c1[512],c2[512],flags; };
struct dpu_hw_intf_status { unsigned int is_en; };
struct dpu_hw_intf { unsigned int idx; bool running; struct { void (*get_status)(struct dpu_hw_intf *,struct dpu_hw_intf_status *); } ops; };
struct dpu_encoder_phys { struct drm_encoder *parent; unsigned int intf_mode,enable_state; struct dpu_hw_intf *hw_intf; };
struct dpu_encoder_virt { struct drm_encoder base; struct mutex enc_lock; bool enabled; unsigned int num_phys_encs; struct dpu_encoder_phys *phys_encs[2]; };
#define to_dpu_kms(x) ((struct dpu_kms *)(x))
#define to_dpu_crtc_state(x) ((struct dpu_crtc_state *)(x))
#define to_dpu_encoder_virt(x) ((struct dpu_encoder_virt *)(x))
#define drm_for_each_encoder_mask(E,D,M) for(unsigned int _ei=0;_ei<2;_ei++) if(((E)=(D)->encoders[_ei]) && ((M)&BIT(_ei)))
#define for_each_oldnew_connector_in_state(S,C,O,N,I) for((I)=0;(I)<(int)(S)->nconn && (((C)=(S)->connector),((O)=(S)->old),((N)=(S)->new),1);(I)++)
static bool drm_atomic_crtc_effectively_active(const struct drm_crtc_state *s) { return s->active||s->self_refresh_active; }
static bool drm_atomic_crtc_needs_modeset(const struct drm_crtc_state *s) { return s->mode_changed; }
static bool drm_connector_atomic_hdr_metadata_equal(struct drm_connector_state *a,struct drm_connector_state *b) { return a->hdr_output_metadata==b->hdr_output_metadata; }
static struct drm_connector *drm_atomic_get_new_connector_for_encoder(struct drm_atomic_commit *s,struct drm_encoder *e) { return s->nconn&&s->connector->encoder==e?s->connector:NULL; }
static struct drm_connector_state *drm_atomic_get_new_connector_state(struct drm_atomic_commit *s,struct drm_connector *c) { return s->connector==c?s->new:NULL; }
/* Exact 10-bit samples below avoid depending on a fake rounding model. */
static unsigned int drm_color_lut_extract(unsigned int v,unsigned int bits) { assert(bits==10 && !(v&63));return v>>6; }
static unsigned int o82_hdr_u16(const u8 *p) { return p[0]|(unsigned int)p[1]<<8; }
static unsigned int uploads,reads,unloads,errors,expected_mask;
static int upload_error;
static bool no_memory;
static u8 factory_gc[6144];
static struct dpu_o82_profiles *expected_profiles;
static struct mutex *expected_lock;
static void *kmalloc(size_t n,int flags) { assert(n==6144 && flags==0);return no_memory?NULL:malloc(n); }
static void kfree(void *p) { free(p); }
#define drm_err(D,F,E) ((void)(D),(void)(F),(void)(E),errors++)
static int dpu_o82_profiles_input(const struct dpu_o82_profiles *p,unsigned int wide,unsigned int pq,struct dpu_o82_color_input *in) {
 assert(expected_lock->held&&p==expected_profiles && p->fw && wide<2 && pq<2);memset(in,0,sizeof(*in));in->gc=factory_gc;in->pa_managed=true;return 0;
}
static void dpu_o82_profiles_unload(struct dpu_o82_profiles *p) { assert(expected_lock->held&&p==expected_profiles);if(p->fw)unloads++;p->fw=NULL; }
static int dpu_o82_power_upload(struct dpu_kms *kms,struct dpu_hw_ctl *ctl,const struct dpu_o82_color_input *in,unsigned int mask) {
 assert(expected_lock->held&&kms&&ctl&&reads>=2&&mask==expected_mask&&in->pa_managed);assert(o82_hdr_u16(in->gc+257*6)==766);
 assert(o82_hdr_u16(in->gc+257*6+2)==42&&o82_hdr_u16(in->gc+257*6+4)==36);uploads++;return upload_error;
}
static void get_status(struct dpu_hw_intf *intf,struct dpu_hw_intf_status *s) { reads++;s->is_en=intf->running; }
#include "actual.h"

int main(void) {
 struct dpu_o82_color color={.profiles={.fw=(void*)1}};
 struct dpu_o82_regdma dma={0};
 struct dpu_kms kms={.o82_color=&color,.o82_regdma=&dma};struct msm_drm_private priv={.kms=&kms.base};
 struct drm_device drm={.dev_private=&priv};struct drm_crtc crtc={.dev=&drm};
 struct dpu_encoder_virt encoder={.base={.dev=&drm,.encoder_type=DRM_MODE_ENCODER_DSI},.num_phys_encs=2};
 struct dpu_hw_intf intf[2]={{.idx=INTF_1,.ops={get_status}},{.idx=INTF_2,.ops={get_status}}};
 struct dpu_encoder_phys phys[2]={{.parent=&encoder.base,.intf_mode=INTF_MODE_VIDEO,.hw_intf=&intf[0]},
  {.parent=&encoder.base,.intf_mode=INTF_MODE_VIDEO,.hw_intf=&intf[1]}};
 encoder.phys_encs[0]=&phys[0];encoder.phys_encs[1]=&phys[1];drm.encoders[0]=&encoder.base;
 struct drm_connector connector={.encoder=&encoder.base};
 struct drm_connector_state old={.crtc=&crtc},conn=old;
 struct drm_atomic_commit atomic={1,&connector,&old,&conn};
 struct dpu_hw_ctl ctl={.ops={dpu_hw_ctl_update_pending_flush_dspp_sub_blocks}};
 struct dpu_hw_dspp dspp[2]={{DSPP_0},{DSPP_1}};
 struct dpu_crtc_state state={.base={.crtc=&crtc,.state=&atomic,.encoder_mask=1,.enable=true,.active=true,.mode_changed=true},
  .num_mixers=2,.num_ctls=1,.mixers={{&dspp[0],&ctl},{&dspp[1],&ctl}},.hw_ctls={&ctl}};
 struct drm_color_lut gamma[1024];struct drm_property_blob gamma_blob={sizeof(gamma),gamma};
 for(unsigned int i=0;i<1024;i++) {
  const unsigned int values[]={i,i/2,i*3/4};
  for(unsigned int c=0;c<3;c++){factory_gc[6*i+2*c]=values[c];factory_gc[6*i+2*c+1]=values[c]>>8;}
  gamma[i]=(struct drm_color_lut){(1023-i)<<6,(i/3)<<6,(i*i/1023)<<6,0};
 }
 state.base.gamma_lut=&gamma_blob;crtc.state=&state.base;expected_profiles=&color.profiles;expected_lock=&color.lock;
 assert(dpu_o82_color_requested(&state.base));assert(!dpu_o82_color_check(&crtc,&state.base));
 dma.closing=true;assert(dpu_o82_color_blocked(&encoder.base)&&dpu_o82_color_check(&crtc,&state.base)==-EIO);
 dma.closing=false;assert(!dpu_o82_color_check(&crtc,&state.base));
 for(unsigned int which=0;which<2;which++) {
  intf[which].running=true;assert(dpu_encoder_o82_stopped(&encoder.base)==-EBUSY);
  reads=uploads=0;assert(dpu_o82_color_commit(&crtc)==-EBUSY&&!uploads&&color.failed);
  assert(dpu_o82_color_blocked(&encoder.base));color.failed=false;intf[which].running=false;
 }
 phys[0].enable_state=1;assert(dpu_encoder_o82_stopped(&encoder.base)==-EBUSY);phys[0].enable_state=0;
 intf[1].idx=INTF_1;assert(dpu_encoder_o82_stopped(&encoder.base)==-EBUSY);intf[1].idx=INTF_2;
 struct dpu_hw_gc_lut gc;assert(!dpu_o82_color_gc(&crtc,&gc));
 assert(gc.c0[128]==(42U|(42U<<16))&&gc.c1[128]==(36U|(36U<<16))&&gc.c2[128]==(767U|(766U<<16)));
 const unsigned int masks[]={3,5,6},ids[][2]={{DSPP_0,DSPP_1},{DSPP_0,DSPP_2},{DSPP_1,DSPP_2}};
 for(unsigned int m=0;m<3;m++) {
  dspp[0].idx=ids[m][0];dspp[1].idx=ids[m][1];expected_mask=masks[m];reads=0;
  memset(ctl.pending_dspp_flush_mask,0,sizeof(ctl.pending_dspp_flush_mask));ctl.pending_flush_mask=0;
  assert(!dpu_o82_color_check(&crtc,&state.base)&&!dpu_o82_color_commit(&crtc));
  assert(ctl.pending_dspp_flush_mask[ids[m][0]-1]==45&&ctl.pending_dspp_flush_mask[ids[m][1]-1]==45);
 }
 for(unsigned int fault=0;fault<2;fault++) {
  upload_error=fault?-EIO:-ETIMEDOUT;u32 old_flush[4];memcpy(old_flush,ctl.pending_dspp_flush_mask,sizeof(old_flush));
  assert(dpu_o82_color_commit(&crtc)==upload_error&&color.failed&&dpu_o82_color_blocked(&encoder.base));
  assert(!memcmp(old_flush,ctl.pending_dspp_flush_mask,sizeof(old_flush)));color.failed=false;
 }
 color.failed=true;
 unsigned int before=uploads;assert(dpu_o82_color_commit(&crtc)==-EIO&&uploads==before);color.failed=false;upload_error=0;
 no_memory=true;assert(dpu_o82_color_commit(&crtc)==-ENOMEM&&uploads==before);no_memory=false;color.failed=false;
 struct hdr_output_metadata hdr={.hdmi_metadata_type1={HDMI_EOTF_SMPTE_ST2084,0}};
 struct drm_property_blob hdr_blob={sizeof(hdr),&hdr};
 for(unsigned int wide=0;wide<2;wide++)for(unsigned int pq=0;pq<2;pq++) {
  conn.colorspace=wide?DRM_MODE_COLORIMETRY_BT2020_RGB:0;conn.hdr_output_metadata=pq?&hdr_blob:NULL;
  assert(!dpu_o82_color_check(&crtc,&state.base)&&state.o82_bt2020==wide&&state.o82_pq==pq);
 }
 state.base.mode_changed=false;dpu_o82_color_mode_changed(&state.base);assert(state.base.mode_changed);
 hdr.hdmi_metadata_type1.eotf=3;assert(dpu_o82_color_check(&crtc,&state.base)==-EOPNOTSUPP);hdr.hdmi_metadata_type1.eotf=2;
 gamma_blob.length--;assert(dpu_o82_color_check(&crtc,&state.base)==-EINVAL);gamma_blob.length++;
 dspp[1].idx=dspp[0].idx;assert(dpu_o82_color_check(&crtc,&state.base)==-EINVAL);dspp[1].idx=DSPP_2;
 state.num_ctls=2;assert(dpu_o82_color_check(&crtc,&state.base)==-EOPNOTSUPP);state.num_ctls=1;
 u32 saved[4];memcpy(saved,ctl.pending_dspp_flush_mask,sizeof(saved));
 dpu_hw_ctl_update_pending_flush_dspp_sub_blocks(&ctl,0,DPU_DSPP_IGC);
 dpu_hw_ctl_update_pending_flush_dspp_sub_blocks(&ctl,DSPP_MAX,DPU_DSPP_GAMUT);
 assert(!memcmp(saved,ctl.pending_dspp_flush_mask,sizeof(saved)));
 dpu_o82_color_fini(&kms);assert(color.failed&&!color.profiles.fw&&unloads==1);
 dpu_o82_color_fini(&kms);assert(unloads==1);
 puts("Actual paired atomic color: both hardware stop states, ownership, four wire inputs, gamma composition, flush bits, failure latch and lifetime passed");
}
