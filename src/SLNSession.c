// Copyright 2014-2015 Ben Trask
// MIT licensed (see LICENSE for details)

#include <openssl/sha.h>
#include "util/pass.h"
#include "StrongLink.h"
#include "SLNDB.h"

#define USER_MIN 2
#define USER_MAX 32
#define PASS_MIN 0
#define PASS_MAX 72

struct SLNSession {
	SLNSessionCacheRef cache;
	uint64_t sessionID;
	byte_t *sessionKeyRaw;
	byte_t *sessionKeyEnc;
	uint64_t userID;
	SLNMode mode;
	str_t *username;
	unsigned refcount; // atomic
};

SLNSessionRef SLNSessionCreateInternal(SLNSessionCacheRef const cache, uint64_t const sessionID, byte_t const *const sessionKeyRaw, byte_t const *const sessionKeyEnc, uint64_t const userID, SLNMode const mode_trusted, strarg_t const username) {
	assert(cache);
	if(!mode_trusted) return NULL;
	SLNSessionRef session = calloc(1, sizeof(struct SLNSession));
	if(!session) return NULL;
	session->cache = cache;
	session->sessionID = sessionID;

	session->sessionKeyRaw = malloc(SESSION_KEY_LEN);
	session->sessionKeyEnc = malloc(SESSION_KEY_LEN);
	if(!session->sessionKeyRaw || !session->sessionKeyEnc) {
		SLNSessionRelease(&session);
		return NULL;
	}
	if(sessionKeyRaw) {
		memcpy(session->sessionKeyRaw, sessionKeyRaw, SESSION_KEY_LEN);
	} else {
		FREE(&session->sessionKeyRaw);
	}
	if(sessionKeyEnc) {
		memcpy(session->sessionKeyEnc, sessionKeyEnc, SESSION_KEY_LEN);
	} else if(sessionKeyRaw) {
		byte_t buf[SHA256_DIGEST_LENGTH];
		SHA256(sessionKeyRaw, SESSION_KEY_LEN, buf);
		memcpy(session->sessionKeyEnc, buf, SESSION_KEY_LEN);
	} else {
		FREE(&session->sessionKeyEnc);
	}

	session->userID = userID;
	session->mode = mode_trusted;
	session->username = username ? strdup(username) : NULL;
	session->refcount = 1;
	return session;
}
SLNSessionRef SLNSessionRetain(SLNSessionRef const session) {
	if(!session) return NULL;
	assert(session->refcount);
	session->refcount++;
	return session;
}
void SLNSessionRelease(SLNSessionRef *const sessionptr) {
	SLNSessionRef session = *sessionptr;
	if(!session) return;
	assert(session->refcount);
	if(--session->refcount) {
		*sessionptr = NULL;
		return;
	}
	session->cache = NULL;
	session->sessionID = 0;
	FREE(&session->sessionKeyRaw);
	FREE(&session->sessionKeyEnc);
	session->userID = 0;
	session->mode = 0;
	FREE(&session->username);
	assert_zeroed(session, 1);
	FREE(sessionptr); session = NULL;
}

SLNSessionCacheRef SLNSessionGetCache(SLNSessionRef const session) {
	if(!session) return NULL;
	return session->cache;
}
SLNRepoRef SLNSessionGetRepo(SLNSessionRef const session) {
	if(!session) return NULL;
	return SLNSessionCacheGetRepo(session->cache);
}
uint64_t SLNSessionGetID(SLNSessionRef const session) {
	if(!session) return 0;
	return session->sessionID;
}
int SLNSessionKeyCmp(SLNSessionRef const session, byte_t const *const enc) {
	if(!session) return -1;
	if(!session->sessionKeyEnc) return -1;
	return memcmp(enc, session->sessionKeyEnc, SESSION_KEY_LEN);
}
uint64_t SLNSessionGetUserID(SLNSessionRef const session) {
	if(!session) return -1;
	return session->userID;
}
bool SLNSessionHasPermission(SLNSessionRef const session, SLNMode const mask) {
	if(!session) return false;
	return (mask & session->mode) == mask;
}
strarg_t SLNSessionGetUsername(SLNSessionRef const session) {
	if(!session) return NULL;
	return session->username;
}
str_t *SLNSessionCopyCookie(SLNSessionRef const session) {
	if(!session) return NULL;
	if(!session->sessionKeyRaw) return NULL;
	str_t hex[SESSION_KEY_HEX+1];
	tohex(hex, session->sessionKeyRaw, SESSION_KEY_LEN);
	hex[SESSION_KEY_HEX] = '\0';
	return aasprintf("s=%llu:%s", (unsigned long long)session->sessionID, hex);
}


int SLNSessionCreateUser(SLNSessionRef const session, DB_txn *const txn, strarg_t const username, strarg_t const password) {
	SLNRepoRef const repo = SLNSessionGetRepo(session);
	SLNMode const mode = SLNRepoGetRegistrationMode(repo);
	return SLNSessionCreateUserInternal(session, txn, username, password, mode);
}
int SLNSessionCreateUserInternal(SLNSessionRef const session, DB_txn *const txn, strarg_t const username, strarg_t const password, SLNMode const mode_unsafe) {
	if(!session) return DB_EINVAL;
	if(!txn) return DB_EINVAL;
	if(!username) return DB_EINVAL;
	if(!password) return DB_EINVAL;
	size_t const ulen = strlen(username);
	size_t const plen = strlen(password);
	if(ulen < USER_MIN || ulen > USER_MAX) return DB_EINVAL;
	if(plen < PASS_MIN || plen > PASS_MAX) return DB_EINVAL;

	SLNMode const mode = mode_unsafe & session->mode;
	if(!mode) return DB_EINVAL;
	uint64_t const parent = session->userID;
	uint64_t const time = uv_now(async_loop); // TODO: Appropriate timestamp?

	uint64_t const userID = db_next_id(SLNUserByID, txn);
	if(!userID) return DB_EACCES;
	str_t *passhash = pass_hash(password);
	if(!passhash) return DB_ENOMEM;

	DB_val username_key[1], userID_val[1];
	SLNUserIDByNameKeyPack(username_key, txn, username);
	SLNUserIDByNameValPack(userID_val, txn, userID);
	int rc = db_put(txn, username_key, userID_val, DB_NOOVERWRITE);
	if(rc < 0) return rc;

	DB_val userID_key[1], user_val[1];
	SLNUserByIDKeyPack(userID_key, txn, userID);
	SLNUserByIDValPack(user_val, txn, username, passhash, NULL, mode, parent, time);
	rc = db_put(txn, userID_key, user_val, DB_NOOVERWRITE);
	if(rc < 0) return rc;

	return 0;
}

int SLNSessionGetFileInfo(SLNSessionRef const session, strarg_t const URI, SLNFileInfo *const info) {
	if(!SLNSessionHasPermission(session, SLN_RDONLY)) return DB_EACCES;
	if(!URI) return DB_EINVAL;

	SLNRepoRef const repo = SLNSessionGetRepo(session);
	DB_env *db = NULL;
	SLNRepoDBOpen(repo, &db);
	DB_txn *txn = NULL;
	int rc = db_txn_begin(db, NULL, DB_RDONLY, &txn);
	if(rc < 0) {
		SLNRepoDBClose(repo, &db);
		return rc;
	}

	DB_cursor *cursor;
	rc = db_txn_cursor(txn, &cursor);
	assert(!rc);

	DB_range fileIDs[1];
	SLNURIAndFileIDRange1(fileIDs, txn, URI);
	DB_val URIAndFileID_key[1];
	rc = db_cursor_firstr(cursor, fileIDs, URIAndFileID_key, NULL, +1);
	DB_val file_val[1];
	if(rc >= 0) {
		strarg_t URI2;
		uint64_t fileID;
		SLNURIAndFileIDKeyUnpack(URIAndFileID_key, txn, &URI2, &fileID);
		assert(0 == strcmp(URI, URI2));
		if(info) {
			DB_val fileID_key[1];
			SLNFileByIDKeyPack(fileID_key, txn, fileID);
			rc = db_get(txn, fileID_key, file_val);
		}
	}
	if(rc < 0) {
		db_txn_abort(txn); txn = NULL;
		SLNRepoDBClose(repo, &db);
		return rc;
	}

	if(info) {
		strarg_t const internalHash = db_read_string(file_val, txn);
		strarg_t const type = db_read_string(file_val, txn);
		uint64_t const size = db_read_uint64(file_val);
		info->hash = strdup(internalHash);
		info->path = SLNRepoCopyInternalPath(repo, internalHash);
		info->type = strdup(type);
		info->size = size;
		if(!info->hash || !info->path || !info->type) {
			SLNFileInfoCleanup(info);
			db_txn_abort(txn); txn = NULL;
			SLNRepoDBClose(repo, &db);
			return DB_ENOMEM;
		}
	}

	db_txn_abort(txn); txn = NULL;
	SLNRepoDBClose(repo, &db);
	return 0;
}
void SLNFileInfoCleanup(SLNFileInfo *const info) {
	if(!info) return;
	FREE(&info->hash);
	FREE(&info->path);
	FREE(&info->type);
	info->size = 0;
	assert_zeroed(info, 1);
}


int SLNSessionGetValueForField(SLNSessionRef const session, str_t value[], size_t const max, strarg_t const fileURI, strarg_t const field) {
	if(!SLNSessionHasPermission(session, SLN_RDONLY)) return DB_EACCES;
	if(!field) return DB_EINVAL;

	if(max) value[0] = '\0';
	int rc = 0;
	DB_cursor *metafiles = NULL;
	DB_cursor *values = NULL;

	SLNRepoRef const repo = SLNSessionGetRepo(session);
	DB_env *db = NULL;
	SLNRepoDBOpen(repo, &db);
	DB_txn *txn = NULL;
	rc = db_txn_begin(db, NULL, DB_RDONLY, &txn);
	if(rc < 0) goto done;

	rc = db_cursor_open(txn, &metafiles);
	if(rc < 0) goto done;
	rc = db_cursor_open(txn, &values);
	if(rc < 0) goto done;

	DB_range metaFileIDs[1];
	SLNTargetURIAndMetaFileIDRange1(metaFileIDs, txn, fileURI);
	DB_val metaFileID_key[1];
	rc = db_cursor_firstr(metafiles, metaFileIDs, metaFileID_key, NULL, +1);
	if(rc < 0 && DB_NOTFOUND != rc) goto done;
	for(; rc >= 0; rc = db_cursor_nextr(metafiles, metaFileIDs, metaFileID_key, NULL, +1)) {
		strarg_t u;
		uint64_t metaFileID;
		SLNTargetURIAndMetaFileIDKeyUnpack(metaFileID_key, txn, &u, &metaFileID);
		assert(0 == strcmp(fileURI, u));
		DB_range vrange[1];
		SLNMetaFileIDFieldAndValueRange2(vrange, txn, metaFileID, field);
		DB_val value_val[1];
		rc = db_cursor_firstr(values, vrange, value_val, NULL, +1);
		if(rc < 0 && DB_NOTFOUND != rc) goto done;
		for(; rc >= 0; rc = db_cursor_nextr(values, vrange, value_val, NULL, +1)) {
			uint64_t m;
			strarg_t f, v;
			SLNMetaFileIDFieldAndValueKeyUnpack(value_val, txn, &m, &f, &v);
			assert(metaFileID == m);
			assert(0 == strcmp(field, f));
			if(!v) continue;
			if(0 == strcmp("", v)) continue;
			size_t const len = strlen(v);
			memcpy(value, v, MIN(len, max-1));
			value[MIN(len, max-1)] = '\0';
			goto done;
		}
	}

done:
	db_cursor_close(values); values = NULL;
	db_cursor_close(metafiles); metafiles = NULL;

	db_txn_abort(txn); txn = NULL;
	SLNRepoDBClose(repo, &db);
	return rc;
}

