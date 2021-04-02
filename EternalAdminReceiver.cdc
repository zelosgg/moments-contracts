/*
    Copied from the AdminReceiver contract except with names changed.
 */

import Eternal from 0xETERNALADDRESS
import EternalShardedCollection from 0xSHARDEDADDRESS

pub contract EternalAdminReceiver {

    // storeAdmin takes a Eternal Admin resource and 
    // saves it to the account storage of the account
    // where the contract is deployed
    pub fun storeAdmin(newAdmin: @Eternal.Admin) {
        self.account.save(<-newAdmin, to: /storage/EternalAdmin)
    }
    
    init() {
        // Save a copy of the sharded Moment Collection to the account storage
        if self.account.borrow<&EternalShardedCollection.ShardedCollection>(from: /storage/EternalShardedMomentCollection) == nil {
            let collection <- EternalShardedCollection.createEmptyCollection(numBuckets: 32)
            // Put a new Collection in storage
            self.account.save(<-collection, to: /storage/EternalShardedMomentCollection)

            self.account.link<&{Eternal.MomentCollectionPublic}>(/public/EternalMomentCollection, target: /storage/EternalShardedMomentCollection)
        }
    }
}
