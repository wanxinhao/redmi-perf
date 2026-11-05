// SPDX-License-Identifier: GPL-2.0
/*
 * redmi_perf_wmi - Xiaomi MIFS SystemPerMode control
 *
 * Talks to the "MiInterface" WMI method exposed by Xiaomi firmware
 * (GUID B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B) and exposes the platform
 * performance mode through sysfs.  On Redmi G / RedmiBook the platform
 * performance mode is what drives the EC-managed GPU TGP and fan curve,
 * which is otherwise stuck at the firmware default (55 W on a 140 W board).
 *
 * The mode encoding was reverse engineered from the Xiaomi Windows control
 * centre; see README.md for the protocol notes.
 *
 * Every protocol offset is a module parameter, so it can be re-calibrated at
 * runtime while reverse engineering without rebuilding the module:
 *
 *   ls /sys/module/redmi_perf_wmi/parameters/
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/hex.h>
#include <linux/ctype.h>
#include <linux/string.h>
#include <linux/device.h>
#include <linux/device/class.h>
#include <linux/sysfs.h>
#include <linux/wmi.h>
#include <linux/acpi.h>
#include <linux/errno.h>

#define MIFS_GUID	"B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B"

#define MIFS_IN_LEN	32
#define MIFS_OUT_LEN	30

/* operation selector inside the InData buffer */
#define MIFS_OP_GET	0xFA
#define MIFS_OP_SET	0xFB

/* command ids of the MIFS interface */
#define MIFS_CMD_PERF_MODE	0x08
#define MIFS_CMD_PSU_TYPE	0x13

/* firmware status codes */
#define MIFS_STATUS_OK			0x80
#define MIFS_STATUS_UNSUPPORTED	0xE0

/*
 * Default byte offsets, overridable at runtime.
 *
 * Measured on a Redmi G Pro 2024 (TM2211) with firmware RMGRP6B0P0909:
 * a GET of command 0x08 answers with
 *
 *   03 00 00 00 20 00 00 00 98 0b 49 42 25 8d ff ff
 *   00 00 00 00 00 00 00 00 00 80 00 08 01 00
 *                     ^^^^^^^^ status  ^^^^^^^^ value
 *                             cmd id echo
 *
 * i.e. the firmware puts the status byte, a reserved byte, the echoed
 * command id and the payload value at the very end of the 30 byte answer.
 * The offsets are found automatically below, this is only the fallback.
 */
#define MIFS_IN_OP		1
#define MIFS_IN_CMD		3
#define MIFS_IN_VALUE		4
#define MIFS_OUT_STATUS		26
#define MIFS_OUT_VALUE		29

enum redmi_perf_mode {
	/*
	 * Two sources disagree about value 0:
	 *
	 *   upstream bitland-mifs-wmi : 0 = Performance
	 *   community capture of the
	 *   Xiaomi Windows control
	 *   centre on Redmi G 2024    : 1 = balanced   (80 W)
	 *                              2 = power-saver (55 W)
	 *                              3 = turbo      (100 W)
	 *                              4 = performance (115 W+)
	 *
	 * They agree on 1, 2 and 4.  Value 0 is undefined in the community
	 * capture, so it is left as "unknown" here and should not be written
	 * blindly.
	 */
	REDMI_PERF_UNKNOWN_0	= 0,
	REDMI_PERF_BALANCED	= 1,
	REDMI_PERF_QUIET	= 2,
	REDMI_PERF_TURBO	= 3,
	REDMI_PERF_FULL_SPEED	= 4,
};

static const char * const redmi_perf_mode_name[] = {
	[REDMI_PERF_UNKNOWN_0]		= "unknown",
	[REDMI_PERF_BALANCED]		= "balanced",
	[REDMI_PERF_QUIET]		= "quiet",
	[REDMI_PERF_TURBO]		= "turbo",
	[REDMI_PERF_FULL_SPEED]		= "full-speed",
};

static unsigned int method_id = 1;
module_param(method_id, uint, 0644);
MODULE_PARM_DESC(method_id, "WMI method id of the MiInterface method");

static unsigned int cmd_id = MIFS_CMD_PERF_MODE;
module_param(cmd_id, uint, 0644);
MODULE_PARM_DESC(cmd_id, "MIFS command id (0x08 = perf mode, 0x13 = PSU type)");

static unsigned int in_op_idx = MIFS_IN_OP;
module_param(in_op_idx, uint, 0644);
MODULE_PARM_DESC(in_op_idx, "offset of the operation byte inside InData");

static unsigned int in_cmd_idx = MIFS_IN_CMD;
module_param(in_cmd_idx, uint, 0644);
MODULE_PARM_DESC(in_cmd_idx, "offset of the command id byte inside InData");

static unsigned int in_val_idx = MIFS_IN_VALUE;
module_param(in_val_idx, uint, 0644);
MODULE_PARM_DESC(in_val_idx, "offset of the value byte inside InData");

static unsigned int out_status_idx = MIFS_OUT_STATUS;
module_param(out_status_idx, uint, 0644);
MODULE_PARM_DESC(out_status_idx, "offset of the status byte inside OutData");

static unsigned int out_value_idx = MIFS_OUT_VALUE;
module_param(out_value_idx, uint, 0644);
MODULE_PARM_DESC(out_value_idx, "offset of the value byte inside OutData");

static bool auto_scan = true;
module_param(auto_scan, bool, 0644);
MODULE_PARM_DESC(auto_scan, "derive the status/value offsets from the command id echo");

struct redmi_perf {
	struct wmi_device *wdev;
	struct device *dev;
	u8 last_status;
	int last_err;
	u8 last_out[MIFS_OUT_LEN];
	size_t last_out_len;
};

static DEFINE_MUTEX(redmi_perf_lock);
static struct class *redmi_perf_class;

/*
 * The firmware echoes the command id back in the answer.  Use that echo to
 * locate the status and value bytes instead of hard coding offsets, so the
 * module keeps working across firmware revisions that shuffle the header.
 *
 * The observed layout puts them at [echo-2] and [echo+1]:
 *
 *   ... 80 00 08 01
 *       ^  ^  ^
 *       |  |  value
 *       |  command id echo
 *       status
 */
static void mifs_locate_fields(const u8 *out, size_t len)
{
	size_t i;

	if (!auto_scan || len < 4)
		return;

	/*
	 * Scan backwards: the echoed command id sits at the very end of the
	 * answer, so the last match is the real one.  Scanning forward could
	 * latch onto a byte in the answer header that happens to have the
	 * same value.
	 */
	for (i = len - 2; i >= 2; i--) {
		if (out[i] != (u8)cmd_id)
			continue;
		if (out[i - 2] != MIFS_STATUS_OK &&
		    out[i - 2] != MIFS_STATUS_UNSUPPORTED)
			continue;

		if (out_status_idx != i - 2 || out_value_idx != i + 1)
			pr_info("auto-detected status at %zu, value at %zu\n",
				i - 2, i + 1);

		out_status_idx = i - 2;
		out_value_idx = i + 1;
		return;
	}
}

/*
 * Issue one MIFS call.
 *
 * in/out are the raw 32/30 byte MIFS buffers.  The ACPI core allocates the
 * output buffer for us (ACPI_ALLOCATE_BUFFER), so we have to release it.
 */
static int mifs_call(struct redmi_perf *rf, const u8 *in, u8 *out, size_t out_len)
{
	struct acpi_buffer in_buf = {
		.length = MIFS_IN_LEN,
		.pointer = (void *)in,
	};
	struct acpi_buffer out_buf = {
		.length = ACPI_ALLOCATE_BUFFER,
		.pointer = NULL,
	};
	acpi_status status;
	size_t len;

	if (!out_len)
		return -EINVAL;

	status = wmidev_evaluate_method(rf->wdev, 0, method_id, &in_buf, &out_buf);
	if (ACPI_FAILURE(status)) {
		rf->last_err = status;
		return -EIO;
	}

	if (!out_buf.pointer) {
		rf->last_err = 0;
		return -EFAULT;
	}

	len = out_buf.length;
	if (len > out_len)
		len = out_len;

	memcpy(out, out_buf.pointer, len);
	memcpy(rf->last_out, out_buf.pointer, len);
	rf->last_out_len = len;
	mifs_locate_fields(out, len);
	rf->last_status = (out_status_idx < len) ? out[out_status_idx] : 0;
	rf->last_err = 0;

	kfree(out_buf.pointer);
	return 0;
}

/* Build and run a GET or SET for the given command id. */
static int mifs_query(struct redmi_perf *rf, u8 op, u8 cmd, u8 value, u8 *out,
		      size_t out_len)
{
	u8 in[MIFS_IN_LEN] = { 0 };

	if (in_op_idx >= MIFS_IN_LEN || in_cmd_idx >= MIFS_IN_LEN ||
	    in_val_idx >= MIFS_IN_LEN)
		return -EINVAL;

	in[in_op_idx] = op;
	in[in_cmd_idx] = cmd;
	in[in_val_idx] = value;

	return mifs_call(rf, in, out, out_len);
}

static int redmi_perf_get(struct redmi_perf *rf, u8 *value)
{
	u8 out[MIFS_OUT_LEN] = { 0 };
	int ret;

	ret = mifs_query(rf, MIFS_OP_GET, cmd_id, 0, out, sizeof(out));
	if (ret)
		return ret;

	if (rf->last_status != MIFS_STATUS_OK)
		return -ENODATA;

	if (out_value_idx >= MIFS_OUT_LEN)
		return -ERANGE;

	*value = out[out_value_idx];
	return 0;
}

static int redmi_perf_set(struct redmi_perf *rf, u8 value)
{
	u8 out[MIFS_OUT_LEN] = { 0 };
	int ret;

	ret = mifs_query(rf, MIFS_OP_SET, cmd_id, value, out, sizeof(out));
	if (ret)
		return ret;

	if (rf->last_status == MIFS_STATUS_UNSUPPORTED)
		return -EOPNOTSUPP;

	if (rf->last_status != MIFS_STATUS_OK)
		return -EIO;

	return 0;
}

static const char *redmi_perf_name_of(u8 value)
{
	if (value < ARRAY_SIZE(redmi_perf_mode_name) &&
	    redmi_perf_mode_name[value])
		return redmi_perf_mode_name[value];
	return "unknown";
}

static int redmi_perf_parse(const char *buf, u8 *value)
{
	unsigned int i, v;
	int ret;

	if (!buf || !buf[0])
		return -EINVAL;

	for (i = 0; i < ARRAY_SIZE(redmi_perf_mode_name); i++) {
		if (!redmi_perf_mode_name[i])
			continue;
		if (!strcasecmp(buf, redmi_perf_mode_name[i])) {
			*value = i;
			return 0;
		}
	}

	/* a few common aliases */
	if (!strcasecmp(buf, "perf"))
		*value = REDMI_PERF_FULL_SPEED;
	else if (!strcasecmp(buf, "bal"))
		*value = REDMI_PERF_BALANCED;
	else if (!strcasecmp(buf, "turbo"))
		*value = REDMI_PERF_TURBO;
	else if (!strcasecmp(buf, "power-saver") ||
		 !strcasecmp(buf, "power_saver") ||
		 !strcasecmp(buf, "saver"))
		*value = REDMI_PERF_QUIET;
	else if (!strcasecmp(buf, "full") || !strcasecmp(buf, "fullspeed"))
		*value = REDMI_PERF_FULL_SPEED;
	else {
		ret = kstrtouint(buf, 0, &v);
		if (ret)
			return ret;
		if (v > 0xff)
			return -ERANGE;
		*value = v;
	}

	return 0;
}

/* ---------------- sysfs ---------------- */

static ssize_t mode_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);
	u8 value;
	int ret;

	mutex_lock(&redmi_perf_lock);
	ret = redmi_perf_get(rf, &value);
	mutex_unlock(&redmi_perf_lock);

	if (ret)
		return sysfs_emit(buf, "error %d (status 0x%02x)\n", ret,
				  rf->last_status);

	return sysfs_emit(buf, "%s (%u)\n", redmi_perf_name_of(value), value);
}

static ssize_t mode_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);
	char tmp[32];
	u8 value;
	int ret;

	if (count >= sizeof(tmp))
		return -EINVAL;
	memcpy(tmp, buf, count);
	tmp[count] = '\0';
	strim(tmp);

	ret = redmi_perf_parse(tmp, &value);
	if (ret)
		return ret;

	mutex_lock(&redmi_perf_lock);
	ret = redmi_perf_set(rf, value);
	mutex_unlock(&redmi_perf_lock);

	if (ret)
		return ret;

	return count;
}
static DEVICE_ATTR_RW(mode);

static ssize_t available_modes_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	size_t len = 0;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(redmi_perf_mode_name); i++) {
		if (!redmi_perf_mode_name[i])
			continue;
		len += sysfs_emit_at(buf, len, "%s%u=%s", len ? " " : "", i,
				      redmi_perf_mode_name[i]);
	}
	len += sysfs_emit_at(buf, len, "\n");

	return len;
}
static DEVICE_ATTR_RO(available_modes);

static ssize_t status_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);

	return sysfs_emit(buf, "status=0x%02x err=%d method_id=%u cmd_id=0x%02x\n",
			  rf->last_status, rf->last_err, method_id, cmd_id);
}
static DEVICE_ATTR_RO(status);

/* Raw escape hatch: write a hex dump of InData, read back the OutData. */
static ssize_t raw_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);
	u8 in[MIFS_IN_LEN] = { 0 };
	u8 out[MIFS_OUT_LEN] = { 0 };
	const char *p = buf;
	char *end;
	size_t n = 0;
	int ret;

	while (*p && n < MIFS_IN_LEN) {
		while (*p == ' ' || *p == ',' || *p == ':' || *p == '\t')
			p++;
		if (!*p)
			break;
		if (!isxdigit(*p))
			return -EINVAL;
		in[n++] = (u8)simple_strtoul(p, &end, 16);
		p = end;
	}

	if (!n)
		return -EINVAL;

	mutex_lock(&redmi_perf_lock);
	ret = mifs_call(rf, in, out, sizeof(out));
	mutex_unlock(&redmi_perf_lock);

	if (ret)
		return ret;

	return count;
}

static ssize_t raw_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);
	size_t i, len = 0;

	for (i = 0; i < rf->last_out_len; i++)
		len += sysfs_emit_at(buf, len, "%02x ", rf->last_out[i]);
	len += sysfs_emit_at(buf, len, "\n");

	return len;
}
static DEVICE_ATTR_RW(raw);

/* PSU type: 1 = USB-C, 2 = DC barrel jack (needed for full performance). */
static ssize_t psu_show(struct device *dev, struct device_attribute *attr,
			 char *buf)
{
	struct redmi_perf *rf = dev_get_drvdata(dev);
	unsigned int save = cmd_id;
	u8 value;
	int ret;

	mutex_lock(&redmi_perf_lock);
	cmd_id = MIFS_CMD_PSU_TYPE;
	ret = redmi_perf_get(rf, &value);
	cmd_id = save;
	mutex_unlock(&redmi_perf_lock);

	if (ret)
		return sysfs_emit(buf, "error %d (status 0x%02x)\n", ret,
				  rf->last_status);

	return sysfs_emit(buf, "%u (%s)\n", value,
			  value == 2 ? "DC" : value == 1 ? "USB-C" : "unknown");
}
static DEVICE_ATTR_RO(psu);

/* ---------------- wmi driver ---------------- */

static const struct wmi_device_id redmi_perf_id_table[] = {
	{ MIFS_GUID },
	{ }
};

static int redmi_perf_probe(struct wmi_device *wdev, const void *context)
{
	struct redmi_perf *rf;
	int ret;

	rf = kzalloc(sizeof(*rf), GFP_KERNEL);
	if (!rf)
		return -ENOMEM;

	rf->wdev = wdev;
	rf->last_status = 0xff;
	dev_set_drvdata(&wdev->dev, rf);

	if (!redmi_perf_class) {
		redmi_perf_class = class_create("redmi_perf");
		if (IS_ERR(redmi_perf_class)) {
			ret = PTR_ERR(redmi_perf_class);
			redmi_perf_class = NULL;
			kfree(rf);
			return ret;
		}
	}

	rf->dev = device_create(redmi_perf_class, NULL, 0, rf, "redmi_perf");
	if (IS_ERR(rf->dev)) {
		ret = PTR_ERR(rf->dev);
		class_destroy(redmi_perf_class);
		redmi_perf_class = NULL;
		kfree(rf);
		return ret;
	}

	ret = device_create_file(rf->dev, &dev_attr_mode);
	if (ret)
		goto err_dev;
	ret = device_create_file(rf->dev, &dev_attr_available_modes);
	if (ret)
		goto err_dev;
	ret = device_create_file(rf->dev, &dev_attr_status);
	if (ret)
		goto err_dev;
	ret = device_create_file(rf->dev, &dev_attr_raw);
	if (ret)
		goto err_dev;
	ret = device_create_file(rf->dev, &dev_attr_psu);
	if (ret)
		goto err_dev;

	pr_info("probe ok, method_id=%u cmd_id=0x%02x\n", method_id, cmd_id);

	/*
	 * First contact: try a GET so the log shows what the firmware answers.
	 * This is the fastest way to tell whether method_id and the byte
	 * offsets are right.
	 */
	mutex_lock(&redmi_perf_lock);
	{
		u8 out[MIFS_OUT_LEN] = { 0 };
		int r = mifs_query(rf, MIFS_OP_GET, cmd_id, 0, out, sizeof(out));

		if (r) {
			pr_info("initial GET failed: %d (acpi status 0x%x)\n",
				r, rf->last_err);
		} else {
			pr_info("initial GET status=0x%02x value=%u out=%*ph\n",
				rf->last_status, out[out_value_idx],
				(int)rf->last_out_len, out);
		}
	}
	mutex_unlock(&redmi_perf_lock);

	return 0;

err_dev:
	device_unregister(rf->dev);
	class_destroy(redmi_perf_class);
	redmi_perf_class = NULL;
	kfree(rf);
	return ret;
}

static void redmi_perf_remove(struct wmi_device *wdev)
{
	struct redmi_perf *rf = dev_get_drvdata(&wdev->dev);

	if (!rf)
		return;

	device_remove_file(rf->dev, &dev_attr_mode);
	device_remove_file(rf->dev, &dev_attr_available_modes);
	device_remove_file(rf->dev, &dev_attr_status);
	device_remove_file(rf->dev, &dev_attr_raw);
	device_remove_file(rf->dev, &dev_attr_psu);
	device_unregister(rf->dev);
	class_destroy(redmi_perf_class);
	redmi_perf_class = NULL;
	kfree(rf);
}

static struct wmi_driver redmi_perf_driver = {
	.driver = {
		.name = "redmi_perf",
	},
	.id_table = redmi_perf_id_table,
	.probe = redmi_perf_probe,
	.remove = redmi_perf_remove,
};

module_wmi_driver(redmi_perf_driver);

MODULE_DESCRIPTION("Xiaomi MIFS platform performance mode control");
MODULE_AUTHOR("redmi-perf");
MODULE_LICENSE("GPL");
