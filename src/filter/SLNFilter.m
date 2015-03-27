#include "SLNFilter.h"

@implementation SLNObject
+ (id)alloc {
	return class_createInstance(self, 0);
}
- (id)init {
	return self;
}
- (void)free {
	size_t const extra = (char *)&isa + sizeof(isa) - (char *)self;
	size_t const len = class_getInstanceSize(isa);
	assert_zeroed((char *)self+extra, len-extra);
	object_dispose(self);
}
@end

@implementation SLNFilter
- (int)addStringArg:(strarg_t const)str :(size_t const)len {
	return -1;
}
- (int)addFilterArg:(SLNFilter *const)filter {
	return -1;
}
- (int)prepare:(DB_txn *const)txn {
	return 0;
}
@end

SLNFilterRef SLNFilterCreate(SLNFilterType const type) {
	switch(type) {
		case SLNAllFilterType:
			return (SLNFilterRef)[[SLNAllFilter alloc] init];
		case SLNFulltextFilterType:
			return (SLNFilterRef)[[SLNFulltextFilter alloc] init];
		case SLNMetadataFilterType:
			return (SLNFilterRef)[[SLNMetadataFilter alloc] init];
		case SLNIntersectionFilterType:
			return (SLNFilterRef)[[SLNIntersectionFilter alloc] init];
		case SLNUnionFilterType:
			return (SLNFilterRef)[[SLNUnionFilter alloc] init];
		case SLNMetaFileFilterType:
			return (SLNFilterRef)[[SLNMetaFileFilter alloc] init];
		default: assert(0); return NULL;
	}
}
SLNFilterRef SLNPermissionFilterCreate(uint64_t const userID) {
	//return (SLNFilterRef)[[SLNPermissionFilter alloc] initWithUserID:userID];
	return NULL; // TODO
}
void SLNFilterFree(SLNFilterRef *const filterptr) {
	[(SLNFilter *)*filterptr free]; *filterptr = NULL;
}
SLNFilterType SLNFilterGetType(SLNFilterRef const filter) {
	assert(filter);
	return [(SLNFilter *)filter type];
}
SLNFilterRef SLNFilterUnwrap(SLNFilterRef const filter) {
	assert(filter);
	return (SLNFilterRef)[(SLNFilter *)filter unwrap];
}
strarg_t SLNFilterGetStringArg(SLNFilterRef const filter, index_t const i) {
	assert(filter);
	return [(SLNFilter *)filter stringArg:i];
}
int SLNFilterAddStringArg(SLNFilterRef const filter, strarg_t const str, ssize_t const len) {
	assert(filter);
	return [(SLNFilter *)filter addStringArg:str :len];
}
int SLNFilterAddFilterArg(SLNFilterRef const filter, SLNFilterRef const subfilter) {
	assert(filter);
	return [(SLNFilter *)filter addFilterArg:(SLNFilter *)subfilter];
}
void SLNFilterPrint(SLNFilterRef const filter, count_t const depth) {
	assert(filter);
	return [(SLNFilter *)filter print:depth];
}
size_t SLNFilterToUserFilterString(SLNFilterRef const filter, str_t *const data, size_t const size, count_t const depth) {
	assert(filter);
	return [(SLNFilter *)filter getUserFilter:data :size :depth];
}
int SLNFilterPrepare(SLNFilterRef const filter, DB_txn *const txn) {
	assert(filter);
	return [(SLNFilter *)filter prepare:txn];
}
void SLNFilterSeek(SLNFilterRef const filter, int const dir, uint64_t const sortID, uint64_t const fileID) {
	[(SLNFilter *)filter seek:dir :sortID :fileID];
}
void SLNFilterCurrent(SLNFilterRef const filter, int const dir, uint64_t *const sortID, uint64_t *const fileID) {
	assert(filter);
	assert(dir);
	[(SLNFilter *)filter current:dir :sortID :fileID];
}
void SLNFilterStep(SLNFilterRef const filter, int const dir) {
	assert(filter);
	assert(dir);
	[(SLNFilter *)filter step:dir];
}
uint64_t SLNFilterAge(SLNFilterRef const filter, uint64_t const sortID, uint64_t const fileID) {
	assert(filter);
	return [(SLNFilter *)filter age:sortID :fileID];
}
str_t *SLNFilterCopyNextURI(SLNFilterRef const filter, int const dir, DB_txn *const txn) {
	for(;; SLNFilterStep(filter, dir)) {
		uint64_t sortID, fileID;
		SLNFilterCurrent(filter, dir, &sortID, &fileID);
		if(!valid(fileID)) return NULL;

//		fprintf(stderr, "step: %llu, %llu\n", (unsigned long long)sortID, (unsigned long long)fileID);

		uint64_t const age = SLNFilterAge(filter, sortID, fileID);
//		fprintf(stderr, "{%llu, %llu} -> %llu\n", (unsigned long long)sortID, (unsigned long long)fileID, (unsigned long long)age);
		if(age != sortID) continue;

		DB_val fileID_key[1];
		SLNFileByIDKeyPack(fileID_key, txn, fileID);
		DB_val file_val[1];
		int rc = db_get(txn, fileID_key, file_val);
		assertf(DB_SUCCESS == rc, "Database error %s", db_strerror(rc));

		strarg_t const hash = db_read_string(file_val, txn);
		assert(hash);
		str_t *const URI = SLNFormatURI(SLN_INTERNAL_ALGO, hash);
		assert(URI);
		SLNFilterStep(filter, dir);
		return URI;
	}
}

