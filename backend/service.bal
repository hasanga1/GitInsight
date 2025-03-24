import ballerina/http;
import ballerina/time;

configurable string GITHUB_TOKEN = ?;

service http:Service / on new http:Listener(9094) {
    resource function get gitInsight/[string username]() returns GitSummery|error {

        // Create GitHub GraphQL API client
        http:Client githubClient = check new ("https://api.github.com/graphql",
            {
                auth: {
                    token: GITHUB_TOKEN
                },
                timeout: 30.0,
                retryConfig: {
                    count: 3,
                    interval: 5.0
                },
                httpVersion: http:HTTP_1_1,
                http1Settings: {
                    keepAlive: http:KEEPALIVE_NEVER
                }
            }
        );

        // First, get user creation date
        json userCreationQuery = {
            "query": string `
            query {
                user(login: "${username}") {
                    createdAt
                    name
                    url
                    followers {
                        totalCount
                    }
                    issues {
                        totalCount
                    }
                    pullRequests {
                        totalCount
                    }
                    repositories {
                        totalCount
                    }
                }
            }
        `
        };

        json userResponse = check githubClient->post("", userCreationQuery);

        if userResponse.data?.user == () {
            return error("User not found: " + username);
        }

        string createdAt = check userResponse.data.user.createdAt;

        time:Utc currentTime = time:utcNow();
        string utcString = time:utcToString(currentTime).substring(0, 19) + "Z";

        // Initialize total contribution counter
        int totalContributions = 0;

        // Extract the year from the createdAt string
        int createdYear = check 'int:fromString(createdAt.substring(0, 4));
        int presentYear = check 'int:fromString(utcString.substring(0, 4));

        // Loop through each year from creation to current
        foreach int year in createdYear ... presentYear {
            string fromDate;
            string toDate;

            fromDate = string `${year}-01-01T00:00:00Z`;
            if year == presentYear {
                toDate = utcString;
            } else {
                toDate = string `${year}-12-31T23:59:59Z`;
            }

            // Query for this year's commits
            json commitQuery = {
                "query": string `
                query {
                    user(login: "${username}") {
                        contributionsCollection(from: "${fromDate}", to: "${toDate}") {
                            totalCommitContributions
                            contributionCalendar {
                                totalContributions
                            }
                        }
                    }
                }
            `
            };

            json commitResponse = check githubClient->post("", commitQuery);

            // Extract and add to total
            int yearContributions = 0;
            if commitResponse.data.user != () && commitResponse.data.user.contributionsCollection != () {
                yearContributions += check commitResponse.data.user.contributionsCollection.contributionCalendar.totalContributions.ensureType(int);
            }
            totalContributions += yearContributions;
        }

        // Query for user's repositories and language stats
        map<int> languageSizes = {};
        int totalSize = 0;
        boolean hasNextPage = true;
        string? endCursor = ();
        int totalCommits = 0;
        int totalStars = 0;
        int totalSizeKB = 0;

        // We need to use pagination since users might have many repositories
        while hasNextPage {
            string afterCursor = endCursor is string ? string `after: "${endCursor}"` : "";

            json repoQuery = {
                "query": string `
                query {
                    user(login: "${username}") {
                        repositories(first: 100, ownerAffiliations: OWNER, ${afterCursor}) {
                            pageInfo {
                                hasNextPage
                                endCursor
                            }
                            nodes {
                                languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                                    edges {
                                        size
                                        node {
                                            name
                                        }
                                    }
                                }
                                name
                                defaultBranchRef {
                                    target {
                                        ... on Commit {
                                            history(first: 1) {
                                                totalCount
                                            }
                                        }
                                    }
                                }
                                stargazerCount
                                diskUsage
                            }
                        }
                    }
                }
            `
            };

            json repoResponse = check githubClient->post("", repoQuery);
            json repositories = check repoResponse.data.user.repositories;

            // Update pagination info
            hasNextPage = check repositories.pageInfo.hasNextPage.ensureType(boolean);
            endCursor = repositories.pageInfo.endCursor is string ? check repositories.pageInfo.endCursor.ensureType() : ();

            // Process languages for each repository
            json[] nodes = check repositories.nodes.ensureType();
            foreach json repo in nodes {
                json[] langEdges = check repo.languages?.edges.ensureType();

                if repo is map<json> && repo.hasKey("defaultBranchRef") {
                    json|error branchRef = repo.defaultBranchRef;
                    if branchRef is map<json> && branchRef.hasKey("target") {
                        json|error target = branchRef.target;
                        if target is map<json> && target.hasKey("history") {
                            json|error history = target.history;
                            if history is map<json> && history.hasKey("totalCount") {
                                json|error count = history.totalCount;
                                if count is int {
                                    totalCommits += count;
                                }
                            }
                        }
                    }
                }

                if repo is map<json> && repo.hasKey("stargazerCount") {
                    json|error starCount = repo.stargazerCount;
                    if starCount is int {
                        totalStars += starCount;
                    }
                }

                if repo is map<json> && repo.hasKey("diskUsage") {
                    json|error diskUsage = repo.diskUsage;
                    if diskUsage is int {
                        totalSizeKB += diskUsage;
                    }
                }

                foreach json edge in langEdges {
                    string langName = check edge.node.name.ensureType();
                    int langSize = check edge.size.ensureType(int);

                    totalSize += langSize;
                    languageSizes[langName] = languageSizes.hasKey(langName) ? languageSizes.get(langName) + langSize : langSize;
                }
            }
        }

        // Calculate percentages for languages
        string[] languages = languageSizes.keys();
        record {|string name; int size; float percentage;|}[] languageStats = [];

        foreach string lang in languages {
            int size = languageSizes.get(lang);
            float percentage = totalSize > 0 ? <float>size * 100.0 / <float>totalSize : 0.0;

            languageStats.push({
                name: lang,
                size: size,
                percentage: percentage
            });
        }

        map<string> languagePercentages = convertToPercentage(languageSizes, totalSize);

        GitSummery gitsummary = {
            name: check userResponse.data.user.name.ensureType(string),
            username: username,
            url: check userResponse.data.user.url.ensureType(string),
            totalFollwers: check userResponse.data.user.followers.totalCount.ensureType(int),
            totalRepos: check userResponse.data.user.repositories.totalCount.ensureType(int),
            totalContributions: totalContributions,
            totalCommits: totalCommits,
            totalStars: totalStars,
            totalIssues: check userResponse.data.user.issues.totalCount.ensureType(int),
            totalPR: check userResponse.data.user.pullRequests.totalCount.ensureType(int),
            languages: languagePercentages,
            totalSizeKB: totalSizeKB
        };
        return gitsummary;
    }
}

function convertToPercentage(map<int> languageSizes, int totalSize) returns map<string> {
    map<string> languagePercentages = {};
    foreach var [lang, size] in languageSizes.entries() {
        float percentage = totalSize > 0 ? (<float>size / <float>totalSize) * 100 : 0;
        languagePercentages[lang] = percentage.round(2).toString() + "%";
    }
    return languagePercentages;
}
