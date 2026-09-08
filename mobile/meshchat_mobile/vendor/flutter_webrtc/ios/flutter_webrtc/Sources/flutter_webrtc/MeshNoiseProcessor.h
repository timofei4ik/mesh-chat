#import "AudioProcessingAdapter.h"

@interface MeshNoiseProcessor : NSObject <ExternalAudioProcessingDelegate>
- (NSDictionary*)status;
@end
