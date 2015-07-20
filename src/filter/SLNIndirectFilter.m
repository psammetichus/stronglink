// Copyright 2014-2015 Ben Trask
// MIT licensed (see LICENSE for details)

#include "SLNFilter.h"
#include "../util/fts.h"

@implementation SLNIndirectFilter
- (void)free {
	curtxn = NULL;
	db_cursor_close(step_target); step_target = NULL;
	db_cursor_close(step_files); step_files = NULL;
	db_cursor_close(age_uris); age_uris = NULL;
	db_cursor_close(age_metafiles); age_metafiles = NULL;
	[super free];
}

- (int)prepare:(DB_txn *const)txn {
	int rc = [super prepare:txn];
	if(rc < 0) return rc;
	db_cursor_renew(txn, &step_target); // SLNMetaFileByID
	db_cursor_renew(txn, &step_files); // SLNURIAndFileID
	db_cursor_renew(txn, &age_uris); // SLNFileIDAndURI
	db_cursor_renew(txn, &age_metafiles); // SLNTargetURIAndMetaFileID
	curtxn = txn;
	return 0;
}
- (void)seek:(int const)dir :(uint64_t const)sortID :(uint64_t const)fileID {
	int rc;
	// TODO: This is copy and pasted from -step:.
	// The only difference is the first iteration, when we -seekMeta::
	// instead of -step: and then seek to the fileID if we got a direct hit.
	// It'd be nice to merge these functions, but I don't want to implement
	// stepping in terms of seeking because it isn't guaranteed to be as
	// fast (depending on the backend, etc).
	uint64_t actualSortID = [self seekMeta:dir :sortID];
	for(; valid(actualSortID); actualSortID = [self stepMeta:dir]) {
		DB_val metaFileID_key[1];
		SLNMetaFileByIDKeyPack(metaFileID_key, curtxn, actualSortID);
		DB_val metaFile_val[1];
		rc = db_cursor_seek(step_target, metaFileID_key, metaFile_val, 0);
		assertf(rc >= 0, "Database error %s", sln_strerror(rc));
		uint64_t f;
		strarg_t targetURI;
		SLNMetaFileByIDValUnpack(metaFile_val, curtxn, &f, &targetURI);

		DB_range fileIDs[1];
		SLNURIAndFileIDRange1(fileIDs, curtxn, targetURI);
		if(actualSortID == sortID) {
			DB_val fileID_key[1];
			SLNURIAndFileIDKeyPack(fileID_key, curtxn, targetURI, fileID);
			rc = db_cursor_seekr(step_files, fileIDs, fileID_key, NULL, dir);
		} else {
			DB_val fileID_key[1];
			rc = db_cursor_firstr(step_files, fileIDs, NULL, NULL, dir);
		}
		if(rc < 0) continue;
		return;
	}
}
- (void)current:(int const)dir :(uint64_t *const)sortID :(uint64_t *const)fileID {
	DB_val fileID_key[1];
	int rc = db_cursor_current(step_files, fileID_key, NULL);
	if(rc >= 0) {
		strarg_t targetURI;
		uint64_t _fileID;
		SLNURIAndFileIDKeyUnpack(fileID_key, curtxn, &targetURI, &_fileID);
		if(sortID) *sortID = [self currentMeta:dir];
		if(fileID) *fileID = _fileID;
	} else {
		if(sortID) *sortID = invalid(dir);
		if(fileID) *fileID = invalid(dir);
	}
}
- (void)step:(int const)dir {
	int rc;
	DB_val fileID_key[1];
	rc = db_cursor_current(step_files, fileID_key, NULL);
	if(rc >= 0) {
		strarg_t targetURI;
		uint64_t fileID;
		SLNURIAndFileIDKeyUnpack(fileID_key, curtxn, &targetURI, &fileID);
		DB_range fileIDs[1];
		SLNURIAndFileIDRange1(fileIDs, curtxn, targetURI);
		rc = db_cursor_nextr(step_files, fileIDs, fileID_key, NULL, dir);
		if(rc >= 0) return;
	}

	uint64_t sortID = [self stepMeta:dir];
	for(; valid(sortID); sortID = [self stepMeta:dir]) {
		DB_val metaFileID_key[1];
		SLNMetaFileByIDKeyPack(metaFileID_key, curtxn, sortID);
		DB_val metaFile_val[1];
		rc = db_cursor_seek(step_target, metaFileID_key, metaFile_val, 0);
		assertf(rc >= 0, "Database error %s", sln_strerror(rc));
		uint64_t f;
		strarg_t targetURI;
		SLNMetaFileByIDValUnpack(metaFile_val, curtxn, &f, &targetURI);

		DB_range fileIDs[1];
		SLNURIAndFileIDRange1(fileIDs, curtxn, targetURI);
		rc = db_cursor_firstr(step_files, fileIDs, NULL, NULL, +1);
		if(rc < 0) continue;
		return;
	}
}
- (SLNAgeRange)fullAge:(uint64_t const)fileID {
	return (SLNAgeRange){ [self fastAge:fileID :UINT64_MAX], UINT64_MAX };
}
- (uint64_t)fastAge:(uint64_t const)fileID :(uint64_t const)sortID {
	uint64_t earliest = UINT64_MAX;
	int rc;

	DB_range URIs[1];
	DB_val URI_key[1];
	SLNFileIDAndURIRange1(URIs, txn, fileID);
	rc = db_cursor_firstr(age_uris, URIs, URI_key, NULL, +1);
	assert(rc >= 0 || DB_NOTFOUND == rc);

	for(; rc >= 0; rc = db_cursor_nextr(age_uris, URIs, URI_key, NULL, +1)) {
		uint64_t f;
		strarg_t targetURI;
		SLNFileIDAndURIKeyUnpack(URI_key, curtxn, &f, &targetURI);
		assert(fileID == f);

		DB_range metafiles[1];
		DB_val metaFileID_key[1];
		SLNTargetURIAndMetaFileIDRange1(metafiles, curtxn, targetURI);
		rc = db_cursor_firstr(age_metafiles, metafiles, metaFileID_key, NULL, +1);
		assert(rc >= 0 || DB_NOTFOUND == rc);
		for(; rc >= 0; rc = db_cursor_nextr(age_metafiles, metafiles, metaFileID_key, NULL, +1)) {
			strarg_t u;
			uint64_t metaFileID;
			SLNTargetURIAndMetaFileIDKeyUnpack(metaFileID_key, curtxn, &u, &metaFileID);
			assert(0 == strcmp(targetURI, u));
			if(metaFileID > sortID) break;
			if(metaFileID >= earliest) break;
			if(![self match:metaFileID]) continue;
			earliest = metaFileID;
			break;
		}
	}
	return earliest;
}
@end

@implementation SLNVisibleFilter
- (void)free {
	db_cursor_close(metafiles); metafiles = NULL;
	[super free];
}

- (SLNFilterType)type {
	return SLNVisibleFilterType;
}
- (void)print:(size_t const)depth {
	indent(depth);
	fprintf(stderr, "(visible)\n");
}
- (size_t)getUserFilter:(str_t *const)data :(size_t const)size :(size_t const)depth {
	if(depth) return wr(data, size, "*");
	return wr(data, size, "");
}

- (int)prepare:(DB_txn *const)txn {
	int rc = [super prepare:txn];
	if(rc < 0) return rc;
	db_cursor_renew(txn, &metafiles); // SLNFirstUniqueMetaFileID
	return 0;
}

- (uint64_t)seekMeta:(int const)dir :(uint64_t const)sortID {
	DB_range range[1];
	SLNFirstUniqueMetaFileIDRange0(range, curtxn);
	DB_val sortID_key[1];
	SLNFirstUniqueMetaFileIDKeyPack(sortID_key, curtxn, sortID);
	int rc = db_cursor_seekr(metafiles, range, sortID_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	uint64_t actualSortID;
	SLNFirstUniqueMetaFileIDKeyUnpack(sortID_key, curtxn, &actualSortID);
	return actualSortID;
}
- (uint64_t)currentMeta:(int const)dir {
	DB_val sortID_key[1];
	int rc = db_cursor_current(metafiles, sortID_key, NULL);
	if(rc < 0) return invalid(dir);
	uint64_t sortID;
	SLNFirstUniqueMetaFileIDKeyUnpack(sortID_key, curtxn, &sortID);
	return sortID;
}
- (uint64_t)stepMeta:(int const)dir {
	DB_range range[1];
	SLNFirstUniqueMetaFileIDRange0(range, curtxn);
	DB_val sortID_key[1];
	int rc = db_cursor_nextr(metafiles, range, sortID_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	uint64_t sortID;
	SLNFirstUniqueMetaFileIDKeyUnpack(sortID_key, curtxn, &sortID);
	return sortID;
}
- (bool)match:(uint64_t const)metaFileID {
	return true;
}
@end

@implementation SLNFulltextFilter
- (void)free {
	FREE(&term);
	for(size_t i = 0; i < count; ++i) {
		FREE(&tokens[i].str);
	}
	assert_zeroed(tokens, count);
	FREE(&tokens);
	count = 0;
	asize = 0;
	db_cursor_close(metafiles); metafiles = NULL;
	db_cursor_close(match); match = NULL;
	[super free];
}

- (SLNFilterType)type {
	return SLNFulltextFilterType;
}
- (strarg_t)stringArg:(size_t const)i {
	if(0 != i) return NULL;
	return term;
}
- (int)addStringArg:(strarg_t const)str :(size_t const)len {
	if(!str) return DB_EINVAL;
	if(0 == len) return DB_EINVAL;
	if(term) return DB_EINVAL;
	if(count) return DB_EINVAL;
	term = strndup(str, len);

	// TODO: libstemmer?
	sqlite3_tokenizer_module const *fts = NULL;
	sqlite3_tokenizer *tokenizer = NULL;
	fts_get(&fts, &tokenizer);

	sqlite3_tokenizer_cursor *tcur = NULL;
	int rc = fts->xOpen(tokenizer, term, strlen(term), &tcur);
	assert(SQLITE_OK == rc);

	for(;;) {
		strarg_t token;
		int tlen;
		int ignored1, ignored2, ignored3;
		rc = fts->xNext(tcur, &token, &tlen, &ignored1, &ignored2, &ignored3);
		if(SQLITE_OK != rc) break;
		if(count+1 > asize) {
			asize = MAX(8, asize*2);
			tokens = reallocarray(tokens, asize, sizeof(tokens[0]));
			assert(tokens); // TODO
		}
		tokens[count].str = strndup(token, tlen);
		assert(tokens[count].str); // TODO
		count++;
	}

	fts->xClose(tcur);

	if(!count) return DB_EINVAL;
	return 0;
}
- (void)print:(size_t const)depth {
	indent(depth);
	fprintf(stderr, "(fulltext %s)\n", term);
}
- (size_t)getUserFilter:(str_t *const)data :(size_t const)size :(size_t const)depth {
	return wr(data, size, term);
}

- (int)prepare:(DB_txn *const)txn {
	int rc = [super prepare:txn];
	if(rc < 0) return rc;
	db_cursor_renew(txn, &metafiles);
	db_cursor_renew(txn, &match);
	return 0;
}

- (uint64_t)seekMeta:(int const)dir :(uint64_t const)sortID {
	assert(count);
	DB_range range[1];
	SLNTermMetaFileIDAndPositionRange1(range, curtxn, tokens[0].str);
	DB_val sortID_key[1];
	SLNTermMetaFileIDAndPositionKeyPack(sortID_key, curtxn, tokens[0].str, sortID, 0);
	// TODO: In order to handle seeking backwards over document with several matching positions, we need to use sortID+1... But sortID might be UINT64_MAX, so be careful.
	int rc = db_cursor_seekr(metafiles, range, sortID_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	strarg_t token;
	uint64_t actualSortID, position;
	SLNTermMetaFileIDAndPositionKeyUnpack(sortID_key, curtxn, &token, &actualSortID, &position);
	assert(0 == strcmp(tokens[0].str, token));
	return actualSortID;
}
- (uint64_t)currentMeta:(int const)dir {
	assert(count);
	DB_val sortID_key[1];
	int rc = db_cursor_current(metafiles, sortID_key, NULL);
	if(rc < 0) return invalid(dir);
	strarg_t token;
	uint64_t sortID, position;
	SLNTermMetaFileIDAndPositionKeyUnpack(sortID_key, curtxn, &token, &sortID, &position);
	assert(0 == strcmp(tokens[0].str, token));
	return sortID;
}
- (uint64_t)stepMeta:(int const)dir {
	assert(count);
	DB_range range[1];
	SLNTermMetaFileIDAndPositionRange1(range, curtxn, tokens[0].str);
	DB_val sortID_key[1];
	int rc = db_cursor_nextr(metafiles, range, sortID_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	strarg_t token;
	uint64_t sortID, position;
	SLNTermMetaFileIDAndPositionKeyUnpack(sortID_key, curtxn, &token, &sortID, &position);
	assert(0 == strcmp(tokens[0].str, token));
	return sortID;
}
- (bool)match:(uint64_t const)metaFileID {
	assert(count);
	DB_range range[1];
	SLNTermMetaFileIDAndPositionRange2(range, curtxn, tokens[0].str, metaFileID);
	DB_val sortID_key[1];
	int rc = db_cursor_firstr(match, range, sortID_key, NULL, +1);
	if(rc >= 0) return true;
	if(DB_NOTFOUND == rc) return false;
	assertf(0, "Database error %s", sln_strerror(rc));
}
@end

@implementation SLNMetadataFilter
- (void)free {
	FREE(&field);
	FREE(&value);
	db_cursor_close(metafiles); metafiles = NULL;
	db_cursor_close(match); match = NULL;
	[super free];
}

- (SLNFilterType)type {
	return SLNMetadataFilterType;
}
- (strarg_t)stringArg:(size_t const)i {
	switch(i) {
		case 0: return field;
		case 1: return value;
		default: return NULL;
	}
}
- (int)addStringArg:(strarg_t const)str :(size_t const)len {
	if(!field) {
		field = strndup(str, len);
		if(!field) return DB_ENOMEM;
		return 0;
	}
	if(!value) {
		value = strndup(str, len);
		if(!value) return DB_ENOMEM;
		return 0;
	}
	return DB_EINVAL;
}
- (void)print:(size_t const)depth {
	indent(depth);
	fprintf(stderr, "(metadata \"%s\" \"%s\")\n", field, value);
}
- (size_t)getUserFilter:(str_t *const)data :(size_t const)size :(size_t const)depth {
	size_t len = 0;
	len += wr_quoted(data+len, size-len, field);
	len += wr(data+len, size-len, "=");
	len += wr_quoted(data+len, size-len, value);
	return len;
}

- (int)prepare:(DB_txn *const)txn {
	int rc = [super prepare:txn];
	if(rc < 0) return rc;
	if(!field || !value) return DB_EINVAL;
	db_cursor_renew(txn, &metafiles); // SLNFieldValueAndMetaFileID
	db_cursor_renew(txn, &match); // SLNFieldValueAndMetaFileID
	return 0;
}

- (uint64_t)seekMeta:(int const)dir :(uint64_t const)sortID {
	DB_range range[1];
	SLNFieldValueAndMetaFileIDRange2(range, curtxn, field, value);
	DB_val metadata_key[1];
	SLNFieldValueAndMetaFileIDKeyPack(metadata_key, curtxn, field, value, sortID);
	int rc = db_cursor_seekr(metafiles, range, metadata_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	strarg_t f, v;
	uint64_t actualSortID;
	SLNFieldValueAndMetaFileIDKeyUnpack(metadata_key, curtxn, &f, &v, &actualSortID);
	return actualSortID;
}
- (uint64_t)currentMeta:(int const)dir {
	DB_val metadata_key[1];
	int rc = db_cursor_current(metafiles, metadata_key, NULL);
	if(rc < 0) return invalid(dir);
	strarg_t f, v;
	uint64_t sortID;
	SLNFieldValueAndMetaFileIDKeyUnpack(metadata_key, curtxn, &f, &v, &sortID);
	return sortID;
}
- (uint64_t)stepMeta:(int const)dir {
	DB_range range[1];
	SLNFieldValueAndMetaFileIDRange2(range, curtxn, field, value);
	DB_val metadata_key[1];
	int rc = db_cursor_nextr(metafiles, range, metadata_key, NULL, dir);
	if(rc < 0) return invalid(dir);
	strarg_t f, v;
	uint64_t sortID;
	SLNFieldValueAndMetaFileIDKeyUnpack(metadata_key, curtxn, &f, &v, &sortID);
	return sortID;
}
- (bool)match:(uint64_t const)metaFileID {
	DB_val metadata_key[1];
	SLNFieldValueAndMetaFileIDKeyPack(metadata_key, curtxn, field, value, metaFileID);
	int rc = db_cursor_seek(match, metadata_key, NULL, 0);
	if(rc >= 0) return true;
	if(DB_NOTFOUND == rc) return false;
	assertf(0, "Database error %s", sln_strerror(rc));
}
@end

