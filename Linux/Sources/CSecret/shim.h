#include <libsecret/secret.h>

// The schema and these attributes live in this device's default collection.
static const SecretSchema vellum_schema = {
    "com.vellum.Credential", SECRET_SCHEMA_NONE, {
        { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
        { "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
        { NULL, 0 }
    }
};

static inline GHashTable *vellum_attributes(const char *service, const char *account) {
    return secret_attributes_build(&vellum_schema, "service", service, "account", account, NULL);
}

static inline SecretCollection *vellum_collection(SecretService **owner, gboolean *absent) {
    // Fresh proxies also see a lock imposed by another process between calls.
    SecretService *service = secret_service_open_sync(secret_service_get_type(), NULL, SECRET_SERVICE_OPEN_SESSION,
                                                       NULL, NULL);
    if (!service) return NULL;
    GError *error = NULL;
    SecretCollection *collection = secret_collection_for_alias_sync(service, SECRET_COLLECTION_DEFAULT,
                                                                    SECRET_COLLECTION_NONE, NULL, &error);
    *absent = !collection && !error;
    if (error) g_error_free(error);
    *owner = service; // SecretCollection holds a weak reference to its service.
    return collection;
}

typedef enum { VELLUM_VALUE, VELLUM_MISSING, VELLUM_UNAVAILABLE } VellumLookup;

// Search without SECRET_SEARCH_UNLOCK. Skipping locked items would turn a
// temporarily inaccessible credential into an apparently disconnected account.
static inline VellumLookup vellum_find(SecretCollection *collection, GHashTable *attributes,
                                       SecretItem **item) {
    if (!collection || secret_collection_get_locked(collection)) return VELLUM_UNAVAILABLE;
    GError *error = NULL;
    GList *matches = secret_collection_search_sync(
        collection, &vellum_schema, attributes, SECRET_SEARCH_ALL, NULL, &error);
    VellumLookup result = VELLUM_UNAVAILABLE;
    if (error) {
        g_error_free(error);
    } else if (!matches) {
        result = VELLUM_MISSING;
    } else if (!matches->next && !secret_item_get_locked(SECRET_ITEM(matches->data))) {
        *item = SECRET_ITEM(g_object_ref(matches->data));
        result = VELLUM_VALUE;
    }
    g_list_free_full(matches, g_object_unref);
    return result;
}

static inline VellumLookup vellum_secret_read(const char *service, const char *account, char **text) {
    gboolean absent = FALSE;
    SecretService *owner = NULL;
    SecretCollection *collection = vellum_collection(&owner, &absent);
    GHashTable *attributes = vellum_attributes(service, account);
    SecretItem *item = NULL;
    VellumLookup result = absent ? VELLUM_MISSING : vellum_find(collection, attributes, &item);
    if (item) {
        SecretValue *value = secret_item_load_secret_sync(item, NULL, NULL) ? secret_item_get_secret(item) : NULL;
        const char *password = value ? secret_value_get_text(value) : NULL;
        if (password) *text = g_strdup(password);
        else result = VELLUM_UNAVAILABLE;
        if (value) secret_value_unref(value);
        g_object_unref(item);
    }
    g_hash_table_unref(attributes);
    if (collection) g_object_unref(collection);
    if (owner) g_object_unref(owner);
    return result;
}

static inline gboolean vellum_secret_write(const char *service, const char *account, const char *text) {
    gboolean absent = FALSE;
    SecretService *owner = NULL;
    SecretCollection *collection = vellum_collection(&owner, &absent);
    if (absent) {
        GHashTable *attributes = vellum_attributes(service, account);
        gboolean stored = secret_password_storev_sync(&vellum_schema, attributes, SECRET_COLLECTION_DEFAULT,
                                                       "Vellum credential", text, NULL, NULL);
        g_hash_table_unref(attributes);
        g_object_unref(owner);
        return stored;
    }
    if (!collection) {
        if (owner) g_object_unref(owner);
        return FALSE;
    }
    gboolean saved = FALSE;
    if (!secret_collection_get_locked(collection)) {
        GHashTable *attributes = vellum_attributes(service, account);
        SecretValue *value = secret_value_new(text, -1, "text/plain");
        SecretItem *item = secret_item_create_sync(collection, &vellum_schema, attributes, "Vellum credential",
                                                  value, SECRET_ITEM_CREATE_REPLACE, NULL, NULL);
        saved = item != NULL;
        if (item) g_object_unref(item);
        secret_value_unref(value);
        g_hash_table_unref(attributes);
    }
    g_object_unref(collection);
    g_object_unref(owner);
    return saved;
}

static inline gboolean vellum_secret_delete(const char *service, const char *account) {
    gboolean absent = FALSE;
    SecretService *owner = NULL;
    SecretCollection *collection = vellum_collection(&owner, &absent);
    GHashTable *attributes = vellum_attributes(service, account);
    SecretItem *item = NULL;
    VellumLookup result = absent ? VELLUM_MISSING : vellum_find(collection, attributes, &item);
    gboolean removed = result == VELLUM_MISSING || (item && secret_item_delete_sync(item, NULL, NULL));
    if (item) g_object_unref(item);
    g_hash_table_unref(attributes);
    if (collection) g_object_unref(collection);
    if (owner) g_object_unref(owner);
    return removed;
}
