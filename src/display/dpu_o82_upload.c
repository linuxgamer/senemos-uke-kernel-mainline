// SPDX-License-Identifier: GPL-2.0-only
/* Native command ownership using Linux MSM GEM, not the OEM buffer allocator. */
#include <linux/err.h>
#include <linux/errno.h>
#include <drm/drm_gpuvm.h>

#include "msm_gem.h"
#include "dpu_kms.h"
#include "dpu_hw_ctl.h"
#include "dpu_o82_lutbus.h"
#include "dpu_o82_regdma.h"
#include "dpu_o82_upload.h"
#include "o82-regdma.h"

static int dpu_o82_upload_buffer(struct dpu_o82_regdma *dma,
				 struct drm_device *drm, struct drm_gpuvm *vm)
{
	struct o82_regdma_descriptor descriptor;
	struct drm_gem_object *bo = NULL;
	u64 iova = 0;
	void *data;

	lockdep_assert_held(&dma->lock);
	if (dma->command_bo)
		return dma->command_vm == vm && dma->command_bo->dev == drm ? 0 : -EINVAL;

	drm_gpuvm_get(vm);
	data = msm_gem_kernel_new(drm, DPU_O82_LUTBUS_MAX_BYTES, MSM_BO_WC, vm, &bo, &iova);
	if (IS_ERR(data)) {
		drm_gpuvm_put(vm);
		return PTR_ERR(data);
	}
	if (!data || !bo ||
	    !drm_gpuvm_range_valid(vm, iova, DPU_O82_LUTBUS_MAX_BYTES) ||
	    !o82_regdma_make_descriptor(1, iova, DPU_O82_LUTBUS_MAX_BYTES, &descriptor)) {
		msm_gem_kernel_put(bo, vm);
		drm_gpuvm_put(vm);
		return -EINVAL;
	}
	dma->command_bo = bo;
	dma->command_vm = vm;
	dma->command_data = data;
	dma->command_iova = iova;
	return 0;
}

int dpu_o82_upload(struct dpu_o82_regdma *dma, struct drm_device *drm,
		   struct drm_gpuvm *vm, struct dpu_hw_ctl *ctl,
		   const struct dpu_o82_color_input *input, unsigned int dspp_mask)
{
	struct o82_regdma_descriptor descriptor;
	size_t bytes = 0;
	int ret;

	if (!dma || !dma->regs || !drm || !vm || vm->drm != drm ||
	    !dma->kms_owner ||
	    dma->kms_owner->o82_regdma != dma || dma->kms_owner->dev != drm ||
	    dma->kms_owner->base.vm != vm || !to_msm_vm(vm)->managed ||
	    !ctl || !ctl->hw.blk_addr || !input ||
	    (dspp_mask != 3 && dspp_mask != 5 && dspp_mask != 6) ||
	    !o82_regdma_make_descriptor(ctl->idx, 0x1000, DPU_O82_LUTBUS_MAX_BYTES, &descriptor))
		return -EINVAL;

	mutex_lock(&dma->lock);
	if (dma->closing) {
		ret = -ESHUTDOWN;
		goto out;
	}
	if (!READ_ONCE(dma->power_held)) {
		ret = -EHOSTDOWN;
		goto out;
	}
	if (dma->quarantined_ctl || dma->bus_isolated) {
		ret = -EBUSY;
		goto out;
	}
	ret = dpu_o82_upload_buffer(dma, drm, vm);
	if (ret)
		goto out;
	ret = dpu_o82_lutbus_build(input, dspp_mask, dma->command_data,
				 DPU_O82_LUTBUS_MAX_BYTES, &bytes);
	if (ret)
		goto out;
	if (bytes != DPU_O82_LUTBUS_BYTES && bytes != DPU_O82_LUTBUS_PA_OFF_BYTES &&
	    bytes != DPU_O82_LUTBUS_SIXZONE_BYTES && bytes != DPU_O82_LUTBUS_MEMORY_BYTES &&
	    bytes != DPU_O82_LUTBUS_MAX_BYTES) {
		ret = -EIO;
		goto out;
	}
	ret = dpu_o82_regdma_execute_locked(dma, ctl, dma->command_iova, bytes);
out:
	mutex_unlock(&dma->lock);
	return ret;
}

int dpu_o82_upload_release(struct dpu_o82_regdma *dma)
{
	int ret = 0;

	if (!dma || !dma->regs)
		return -EINVAL;
	mutex_lock(&dma->lock);
	if (dma->quarantined_ctl && !dma->bus_isolated) {
		ret = -EBUSY;
		goto out;
	}
	if (dma->command_bo) {
		if (!dma->kms_owner || dma->kms_owner->o82_regdma != dma ||
		    dma->command_vm != dma->kms_owner->base.vm ||
		    dma->command_bo->dev != dma->kms_owner->dev) {
			ret = -EINVAL;
			goto out;
		}
		msm_gem_kernel_put(dma->command_bo, dma->command_vm);
		drm_gpuvm_put(dma->command_vm);
		dma->command_bo = NULL;
		dma->command_vm = NULL;
		dma->command_data = NULL;
		dma->command_iova = 0;
	}
out:
	mutex_unlock(&dma->lock);
	return ret;
}
