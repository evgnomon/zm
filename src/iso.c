#include <sys/types.h>
#include <sys/stat.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <libisofs/libisofs.h>
#include <libisoburn/libisoburn.h>
#include <libburn/libburn.h>

int zm_geniso(const char* output, const char* user_data, const char* meta_data) {
    if (!output || !user_data || !meta_data) return EINVAL;

    char msg[1024] = {0};
    if (isoburn_initialize(msg, 0) <= 0) {
        return 126; // initialization failure
    }
    if (iso_init() < 0) {
        return 126;
    }

    IsoImage *image = NULL;
    if (iso_image_new("cidata", &image) < 0 || image == NULL) {
        return 126;
    }

    iso_image_set_volume_id(image, "cidata");

    IsoDir *root = iso_image_get_root(image);
    if (root == NULL) {
        iso_image_unref(image);
        return 126;
    }

    // Add files into ISO root with required names
    IsoNode *tmp_node = NULL;
    if (iso_tree_add_new_node(image, root, "user-data", user_data, &tmp_node) < 0) {
        iso_image_unref(image);
        return 125;
    }
    tmp_node = NULL;
    if (iso_tree_add_new_node(image, root, "meta-data", meta_data, &tmp_node) < 0) {
        iso_image_unref(image);
        return 125;
    }

    IsoWriteOpts *opts = NULL;
    if (iso_write_opts_new(&opts, 2) < 0 || opts == NULL) { iso_image_unref(image); return 126; }
    iso_write_opts_set_rockridge(opts, 1);
    iso_write_opts_set_joliet(opts, 1);

    struct burn_source *burn_src = NULL;
    if (iso_image_create_burn_source(image, opts, &burn_src) < 0 || burn_src == NULL) {
        iso_write_opts_free(opts);
        iso_image_unref(image);
        return 126;
    }

    int fd = open(output, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) {
        burn_source_free(burn_src);
        iso_write_opts_free(opts);
        iso_image_unref(image);
        return errno;
    }

    int r = 0;
    unsigned char buffer[2048];
    while (1) {
        int chunk = (burn_src->read ? burn_src->read(burn_src, buffer, (int)sizeof(buffer)) : burn_src->read_xt(burn_src, buffer, (int)sizeof(buffer)));
        if (chunk < 0) { r = -1; break; }
        if (chunk == 0) { break; }
        ssize_t w = write(fd, buffer, chunk);
        if (w != chunk) { r = -1; break; }
    }
    close(fd);

    burn_source_free(burn_src);
    iso_write_opts_free(opts);
    iso_image_unref(image);

    if (r < 0) return 125;
    return 0;
}
