    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.24;

    /**
     * @title Canteen
     * @dev Container orchestration with FHE encrypted memory management
     * Supports multiple containers per node
     */
    contract Canteen {
        struct Member {
            string imageName;  // Kept for backward compatibility, stores last assigned image
            bytes encryptedMemory;  // FHE encrypted memory value
            bool active;
        }

        struct Image {
            uint replicas;
            uint deployed;
            bool active;
        }

        address public owner;

        event MemberJoin(string host, bytes encryptedMemory);
        event MemberLeave(string host);
        event MemberImageUpdate(string host, string image);
        event MemberMemoryUpdate(string host, bytes newEncryptedMemory);
        event ContainerAssigned(string host, string image, uint containerId);
        event ContainerRemoved(string host, string image, uint containerId);
        event DeploymentQueued(string image, uint remaining);
        event DeploymentCompleted(string image);

        mapping(bytes32 => Member) memberDetails;
        string[] public members;

        // Track container count per member (more gas efficient than arrays)
        mapping(bytes32 => uint) public memberContainerCount;
        
        // Track container assignments: memberContainers[hostHash][containerId] = imageName
        mapping(bytes32 => mapping(uint => string)) public memberContainers;

        // Deployment queue: tracks pending container deployments
        mapping(bytes32 => uint) public pendingDeployments;  // imageName -> count of pending deployments

        mapping(bytes32 => Image) imageDetails;
        string[] public images;
        mapping (bytes32 => uint[2][]) exposedPortsForImages;

        uint MULT = 100000;

        modifier restricted() {
            require(msg.sender == owner, "Only owner can call this");
            _;
        }

        constructor() {
            owner = msg.sender;
        }

        /**
         * @dev Register a new member with encrypted memory
         * @param host The host identifier (peer ID)
         * @param encryptedMemory The FHE encrypted memory value (pass empty bytes for backward compatibility)
         */
        function addMember(string memory host, bytes memory encryptedMemory) restricted public {
            bytes32 hashedHost = keccak256(abi.encodePacked(host));
            require(!memberDetails[hashedHost].active);

            members.push(host);
            memberDetails[hashedHost] = Member("", encryptedMemory, true);

            emit MemberJoin(host, encryptedMemory);
            setImageForMember(host);
        }

        /**
         * @dev Backward compatible addMember without encrypted memory
         */
        function addMember(string memory host) restricted public {
            addMember(host, "");
        }

        /**
         * @dev Update member's encrypted memory after deployment
         * @param host The host identifier
         * @param newEncryptedMemory The new FHE encrypted memory value
         */
        function updateMemberMemory(string memory host, bytes memory newEncryptedMemory) restricted public {
            bytes32 hashedHost = keccak256(abi.encodePacked(host));
            require(memberDetails[hashedHost].active, "Member not active");

            memberDetails[hashedHost].encryptedMemory = newEncryptedMemory;
            emit MemberMemoryUpdate(host, newEncryptedMemory);
            
            // After memory update, check if there are pending deployments and deploy next
            deployNextPendingContainer();
        }
        
        /**
         * @dev Deploy next pending container from any image's queue
         */
        function deployNextPendingContainer() private {
            // Check all images for pending deployments
            for (uint i = 0; i < images.length; i++) {
                bytes32 hashedImage = keccak256(abi.encodePacked(images[i]));
                
                if (pendingDeployments[hashedImage] > 0 && imageDetails[hashedImage].active) {
                    deployNextContainer(images[i]);
                    return;  // Deploy one at a time
                }
            }
        }

        /**
         * @dev Get member's encrypted memory
         */
        function getMemberEncryptedMemory(string memory host) public view returns (bytes memory) {
            return memberDetails[keccak256(abi.encodePacked(host))].encryptedMemory;
        }

        function removeMember(string memory host) restricted public {
            bytes32 hashedHost = keccak256(abi.encodePacked(host));
            require(memberDetails[hashedHost].active);

            // Track all unique images that were on this node for redeployment
            string[] memory affectedImages = new string[](memberContainerCount[hashedHost]);
            uint uniqueImageCount = 0;
            
            // Clean up all containers assigned to this member
            uint containerCount = memberContainerCount[hashedHost];
            for (uint i = 0; i < containerCount; i++) {
                string memory containerImage = memberContainers[hashedHost][i];
                if (bytes(containerImage).length > 0) {
                    bytes32 hashedImage = keccak256(abi.encodePacked(containerImage));
                    
                    // Decrement deployed count for this image
                    if (imageDetails[hashedImage].deployed > 0) {
                        imageDetails[hashedImage].deployed -= 1;
                    }
                    
                    // Add to pending deployments queue for redeployment
                    pendingDeployments[hashedImage] += 1;
                    
                    // Track unique images
                    bool alreadyTracked = false;
                    for (uint j = 0; j < uniqueImageCount; j++) {
                        if (keccak256(abi.encodePacked(affectedImages[j])) == hashedImage) {
                            alreadyTracked = true;
                            break;
                        }
                    }
                    if (!alreadyTracked) {
                        affectedImages[uniqueImageCount] = containerImage;
                        uniqueImageCount++;
                    }
                    
                    // Clear the container slot
                    delete memberContainers[hashedHost][i];
                }
            }
            
            // Reset container count
            memberContainerCount[hashedHost] = 0;
            
            // Mark member as inactive
            memberDetails[hashedHost] = Member("", "", false);

            emit MemberLeave(host);
            
            // Trigger redeployment of affected containers on remaining nodes
            for (uint i = 0; i < uniqueImageCount; i++) {
                emit DeploymentQueued(affectedImages[i], pendingDeployments[keccak256(abi.encodePacked(affectedImages[i]))]);
                deployNextContainer(affectedImages[i]);
            }
        }

        function addImage(string memory name, uint replicas) restricted public {
            bytes32 hashedName = keccak256(abi.encodePacked(name));
            require(bytes(name).length > 0);
            require(replicas > 0);
            
            // Check if image already exists
            bool imageExists = false;
            for (uint i = 0; i < images.length; i++) {
                if (keccak256(abi.encodePacked(images[i])) == hashedName) {
                    imageExists = true;
                    break;
                }
            }
            
            // Only push to array if this is a completely new image
            if (!imageExists) {
                images.push(name);
            }
            
            // If image was previously active, reactivating it requires it to be inactive first
            require(!imageDetails[hashedName].active, "Image already active");
            
            // Set/reset image details (resets deployed count to 0)
            imageDetails[hashedName] = Image(replicas, 0, true);

            // Queue all replicas for sequential deployment
            pendingDeployments[hashedName] = replicas;
            
            emit DeploymentQueued(name, replicas);
            
            // Deploy first container immediately
            deployNextContainer(name);
        }

        function removeImage(string memory name) restricted public {
            bytes32 hashedName = keccak256(abi.encodePacked(name));
            require(imageDetails[hashedName].active);

            imageDetails[hashedName].active = false;

            // Remove all container assignments for this image from all members
            for (uint i = 0; i < members.length; i++) {
                string memory host = members[i];
                bytes32 hashedHost = keccak256(abi.encodePacked(host));
                Member storage member = memberDetails[hashedHost];
                
                if (!member.active) {
                    continue;
                }
                
                // Remove all containers of this image from this member
                uint containerCount = memberContainerCount[hashedHost];
                uint newContainerIndex = 0;
                
                // Track removed containers for events
                for (uint j = 0; j < containerCount; j++) {
                    string memory containerImage = memberContainers[hashedHost][j];
                    
                    if (keccak256(abi.encodePacked(containerImage)) == hashedName) {
                        // This container uses the removed image - emit event and skip it
                        emit ContainerRemoved(host, name, j);
                        
                        // Decrement deployed count
                        if (imageDetails[hashedName].deployed > 0) {
                            imageDetails[hashedName].deployed -= 1;
                        }
                        
                        // Clear the slot
                        delete memberContainers[hashedHost][j];
                    } else {
                        // Keep this container - compact the array if needed
                        if (newContainerIndex != j) {
                            memberContainers[hashedHost][newContainerIndex] = containerImage;
                            delete memberContainers[hashedHost][j];
                        }
                        newContainerIndex++;
                    }
                }
                
                // Update container count
                memberContainerCount[hashedHost] = newContainerIndex;
                
                // Update backward-compatible imageName field
                if (keccak256(abi.encodePacked(member.imageName)) == hashedName) {
                    member.imageName = "";
                }
            }
        }

        function addPortForImage(string memory name, uint from, uint to) restricted public {
            exposedPortsForImages[keccak256(abi.encodePacked(name))].push([from, to]);
        }

         function getPortsForImage(string memory name) restricted public view returns (uint[2][] memory) {
            return exposedPortsForImages[keccak256(abi.encodePacked(name))];
        }

        function getMemberDetails(string memory host) public view returns (string memory, bool, bytes memory) {
            Member storage details = memberDetails[keccak256(abi.encodePacked(host))];
            return (details.imageName, details.active, details.encryptedMemory);
        }

        /**
         * @dev Get all images assigned to a member (supports multiple containers per node)
         * @param host The host identifier
         * @return Array of image names assigned to this host
         */
        function getMemberImages(string memory host) public view returns (string[] memory) {
            bytes32 hashedHost = keccak256(abi.encodePacked(host));
            uint count = memberContainerCount[hashedHost];
            string[] memory images_list = new string[](count);
            
            for (uint i = 0; i < count; i++) {
                images_list[i] = memberContainers[hashedHost][i];
            }
            
            return images_list;
        }

        /**
         * @dev Get all hosts running a specific image
         * @param imageName The image name
         * @return Array of host identifiers running this image
         */
        function getImageHosts(string memory imageName) public view returns (string[] memory) {
            // Iterate through members and find those running this image
            bytes32 hashedImage = keccak256(abi.encodePacked(imageName));
            uint matchCount = 0;
            
            // First pass: count matches
            for (uint i = 0; i < members.length; i++) {
                bytes32 hashedMember = keccak256(abi.encodePacked(members[i]));
                uint containerCount = memberContainerCount[hashedMember];
                
                for (uint j = 0; j < containerCount; j++) {
                    if (keccak256(abi.encodePacked(memberContainers[hashedMember][j])) == hashedImage) {
                        matchCount++;
                        break;  // Count each member only once
                    }
                }
            }
            
            // Second pass: collect matches
            string[] memory hosts = new string[](matchCount);
            uint currentIndex = 0;
            
            for (uint i = 0; i < members.length; i++) {
                bytes32 hashedMember = keccak256(abi.encodePacked(members[i]));
                uint containerCount = memberContainerCount[hashedMember];
                
                for (uint j = 0; j < containerCount; j++) {
                    if (keccak256(abi.encodePacked(memberContainers[hashedMember][j])) == hashedImage) {
                        hosts[currentIndex] = members[i];
                        currentIndex++;
                        break;  // Count each member only once
                    }
                }
            }
            
            return hosts;
        }

        function getImageDetails(string memory name) public view returns (uint, uint, bool) {
            Image storage details = imageDetails[keccak256(abi.encodePacked(name))];
            return (details.replicas, details.deployed, details.active);
        }
        
        /**
         * @dev Deploy next container from the queue for specified image
         * @param imageName The image to deploy
         */
        function deployNextContainer(string memory imageName) private {
            bytes32 hashedImage = keccak256(abi.encodePacked(imageName));
            
            // Check if there are pending deployments
            if (pendingDeployments[hashedImage] == 0) {
                return;
            }
            
            Image storage image = imageDetails[hashedImage];
            
            // Check if we've reached the target
            if (image.deployed >= image.replicas) {
                pendingDeployments[hashedImage] = 0;
                emit DeploymentCompleted(imageName);
                return;
            }
            
            // Find node with highest memory and lowest container count
            string memory bestHost = findNodeWithHighestMemory(imageName);
            
            if (keccak256(abi.encodePacked(bestHost)) == keccak256(abi.encodePacked(""))) {
                // No available node found - keep in queue
                emit DeploymentQueued(imageName, pendingDeployments[hashedImage]);
                return;
            }
            
            bytes32 hashedBestHost = keccak256(abi.encodePacked(bestHost));
            
            // Add this image to the member's container list
            uint containerIndex = memberContainerCount[hashedBestHost];
            memberContainers[hashedBestHost][containerIndex] = imageName;
            memberContainerCount[hashedBestHost]++;
            
            // Update the last assigned image (for backward compatibility)
            memberDetails[hashedBestHost].imageName = imageName;
            
            image.deployed += 1;
            pendingDeployments[hashedImage] -= 1;
            
            emit MemberImageUpdate(bestHost, imageName);
            emit ContainerAssigned(bestHost, imageName, containerIndex);
            
            if (pendingDeployments[hashedImage] > 0) {
                emit DeploymentQueued(imageName, pendingDeployments[hashedImage]);
            } else {
                emit DeploymentCompleted(imageName);
            }
        }

        function rebalanceWithUnfortunateImage(string memory newImageName) private {
            Image storage newImage = imageDetails[keccak256(abi.encodePacked(newImageName))];
            
            // Deploy replicas one by one, selecting node with highest available memory each time
            // Supports multiple replicas per node - will round-robin across nodes
            while (newImage.deployed < newImage.replicas) {
                // Find node with highest memory (can now reuse nodes for multiple containers)
                string memory bestHost = findNodeWithHighestMemory("");
                
                if (keccak256(abi.encodePacked(bestHost)) == keccak256(abi.encodePacked(""))) {
                    // No available node found
                    break;
                }
                
                bytes32 hashedBestHost = keccak256(abi.encodePacked(bestHost));
                
                // Add this image to the member's container list (more gas efficient than arrays)
                uint containerIndex = memberContainerCount[hashedBestHost];
                memberContainers[hashedBestHost][containerIndex] = newImageName;
                memberContainerCount[hashedBestHost]++;
                
                // Update the last assigned image (for backward compatibility)
                memberDetails[hashedBestHost].imageName = newImageName;
                
                newImage.deployed += 1;
                
                emit MemberImageUpdate(bestHost, newImageName);
                emit ContainerAssigned(bestHost, newImageName, containerIndex);
            }
        }

        function setImageForMember(string memory host) private {
            string memory image = getNextImageToUse();
            bytes32 hashedHost = keccak256(abi.encodePacked(host));
            bytes32 hashedImage = keccak256(abi.encodePacked(image));
            if (hashedImage == keccak256(abi.encodePacked(""))) {
                return;
            }

            // Host currently has no image, and image hasn't reached its limit yet.
            require(keccak256(abi.encodePacked(memberDetails[hashedHost].imageName)) == keccak256(abi.encodePacked("")));
            require(imageDetails[hashedImage].deployed < imageDetails[hashedImage].replicas);

            // Instead of assigning to the requesting host, find the node with highest memory
            string memory bestHost = findNodeWithHighestMemory(image);
            
            // If no suitable host found with FHE comparison, use the requesting host
            if (keccak256(abi.encodePacked(bestHost)) == keccak256(abi.encodePacked(""))) {
                bestHost = host;
            }
            
            bytes32 hashedBestHost = keccak256(abi.encodePacked(bestHost));
            memberDetails[hashedBestHost].imageName = image;
            imageDetails[hashedImage].deployed += 1;
            emit MemberImageUpdate(bestHost, image);
        }

        /**
         * @dev Find node with highest encrypted memory for image deployment.
         * Uses FHE comparison to select optimal node without decrypting memory values.
         * Considers container count to balance load across nodes.
         * @return The host with highest encrypted memory and lowest container count
         */
        function findNodeWithHighestMemory(string memory) private view returns (string memory) {
            string memory bestHost = "";
            bytes memory highestMemory = "";
            uint lowestContainerCount = type(uint).max;
            
            // Iterate through all members to find the one with highest encrypted memory
            // and lowest container count (for load balancing)
            for (uint i = 0; i < members.length; i++) {
                bytes32 hashedMember = keccak256(abi.encodePacked(members[i]));
                Member storage member = memberDetails[hashedMember];
                
                // Skip if not active
                if (!member.active) {
                    continue;
                }
                
                // Skip if no encrypted memory data
                if (member.encryptedMemory.length == 0) {
                    continue;
                }
                
                uint containerCount = memberContainerCount[hashedMember];
                
                // First valid member becomes initial candidate
                if (highestMemory.length == 0) {
                    bestHost = members[i];
                    highestMemory = member.encryptedMemory;
                    lowestContainerCount = containerCount;
                    continue;
                }
                
                // Prefer nodes with fewer containers for better distribution
                // Only compare memory if container counts are equal
                if (containerCount < lowestContainerCount) {
                    // This node has fewer containers, prefer it
                    bestHost = members[i];
                    highestMemory = member.encryptedMemory;
                    lowestContainerCount = containerCount;
                } else if (containerCount == lowestContainerCount) {
                    // Same container count, use FHE memory comparison
                    if (compareEncryptedMemory(member.encryptedMemory, highestMemory)) {
                        bestHost = members[i];
                        highestMemory = member.encryptedMemory;
                        lowestContainerCount = containerCount;
                    }
                }
                // If this node has more containers, skip it
            }
            
            return bestHost;
        }

        /**
         * @dev Compare two encrypted memory values.
         * Returns true if memoryA > memoryB (encrypted comparison).
         * 
         * NOTE: This is a placeholder for actual FHE comparison.
         * In production with Zama fhEVM, this would perform homomorphic comparison
         * without ever decrypting the values.
         * 
         * @param memoryA First encrypted memory value
         * @param memoryB Second encrypted memory value
         * @return true if memoryA > memoryB
         */
        function compareEncryptedMemory(bytes memory memoryA, bytes memory memoryB) private pure returns (bool) {
            // Placeholder: In production, this would use Zama fhEVM's euint comparison
            // For now, we compare based on ciphertext size (longer = more precision = likely higher value)
            // This is NOT cryptographically correct but demonstrates the architecture
            
            // In real implementation with fhEVM:
            // euint32 valueA = TFHE.asEuint32(memoryA);
            // euint32 valueB = TFHE.asEuint32(memoryB);
            // return TFHE.decrypt(TFHE.gt(valueA, valueB));
            
            return memoryA.length >= memoryB.length;
        }

        // Selects image with lowest usage, scales equal usage of all replicas,
        // with respect to the ratio of the replicas required.
        function getNextImageToUse() private view returns (string memory) {
            string memory bestImage = "";
            uint lowestUsage = MULT;

            for (uint i = 0; i < images.length; i++) {
                bytes32 hash = keccak256(abi.encodePacked(images[i]));
                Image storage image = imageDetails[hash];

                if (image.deployed >= image.replicas)
                    continue;

                // deployed / usage < lowestUsage -> this has lower usage
                if (image.active && image.deployed < lowestUsage * image.replicas) {
                    lowestUsage = (image.deployed * MULT) / image.replicas;
                    bestImage = images[i];
                }
            }

            return bestImage;
        }

        function getMembersCount() public view returns (uint) {
            return members.length;
        }

        function getImagesCount() public view returns (uint) {
            return images.length;
        }
    }